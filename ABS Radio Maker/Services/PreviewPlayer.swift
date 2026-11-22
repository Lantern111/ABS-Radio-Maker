import Accelerate
import AVFoundation
import Observation

/// What the meter shows, in dBFS for the levels and LUFS for loudness.
struct MeterReading: Equatable, Sendable {
    var peak: [Float] = [-120, -120]
    var rms: [Float] = [-120, -120]
    /// The highest peak lately, held for a moment so it can be read.
    var hold: [Float] = [-120, -120]
    /// A sample reached full scale. Stays lit until clicked.
    var clipped = false
    /// Loudness over the last 0.4 seconds.
    var momentary: Double?
    /// Loudness over the last 3 seconds.
    var shortTerm: Double?

    static let silent = MeterReading()
}

/// Plays the cleaned-up recording through the plug-ins live, then the same loudness gain the export gets and a limiter,
/// so the preview sounds like the finished video and plug-in settings can be heard as they change. The picture and
/// the timeline follow `time`; the meter follows `meter`.
@MainActor @Observable final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    /// Where playback is, in seconds. Updated 30 times a second while playing, so anything that shows it moves along.
    private(set) var time: Double = 0
    /// 1 is normal speed. Pressing L again while playing doubles it, up to 2.
    private(set) var rate: Float = 1
    private(set) var meter = MeterReading.silent

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let node = AVAudioPlayerNode()
    @ObservationIgnored private let speed = AVAudioUnitTimePitch()
    @ObservationIgnored private let gain = AVAudioUnitEQ(numberOfBands: 0)
    @ObservationIgnored private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    ))
    @ObservationIgnored private var effects: [AVAudioUnit] = []
    @ObservationIgnored private var file: AVAudioFile?
    /// The frame of the file the current playback was scheduled from.
    @ObservationIgnored private var scheduledFrom: AVAudioFramePosition = 0
    /// Goes up with every new schedule, so a finished-playing message from an old one is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var levels: LevelTap?
    @ObservationIgnored private var holdSince: [Date] = [.distantPast, .distantPast]
    @ObservationIgnored private var stoppedAt: Date?

    init() {
        engine.attach(node)
        engine.attach(speed)
        engine.attach(gain)
        engine.attach(limiter)
        connect()
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // The output device changed or went away, which stops the engine. Playback stops where it was.
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.pause()
            }
        }
    }

    private var format: AVAudioFormat {
        file?.processingFormat ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    }

    /// Player → speed → plug-ins → loudness gain → limiter → output, with the meter listening at the end.
    private func connect() {
        let chain: [AVAudioNode] = [node, speed] + effects + [gain, limiter]
        for item in chain { engine.disconnectNodeOutput(item) }
        let format = format
        for (from, to) in zip(chain, chain.dropFirst()) {
            engine.connect(from, to: to, format: format)
        }
        engine.connect(limiter, to: engine.mainMixerNode, format: format)

        let mixer = engine.mainMixerNode
        mixer.removeTap(onBus: 0)
        let outputFormat = mixer.outputFormat(forBus: 0)
        let tap = LevelTap(sampleRate: outputFormat.sampleRate, channels: Int(outputFormat.channelCount))
        levels = tap
        mixer.installTap(onBus: 0, bufferSize: 2048, format: outputFormat) { buffer, _ in
            tap.measure(buffer)
        }
    }

    func load(_ url: URL) {
        let keepTime = time
        stopPlaying()
        file = try? AVAudioFile(forReading: url)
        duration = file.map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        connect()
        time = min(keepTime, duration)
    }

    func unload() {
        stopPlaying()
        file = nil
        duration = 0
        time = 0
    }

    /// The plug-ins that play live, in order. Playback carries on where it was.
    func setEffects(_ units: [AVAudioUnit]) {
        guard units.map(ObjectIdentifier.init) != effects.map(ObjectIdentifier.init) else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        for unit in effects where !units.contains(where: { $0 === unit }) {
            engine.detach(unit)
        }
        for unit in units where !effects.contains(where: { $0 === unit }) {
            engine.attach(unit)
        }
        effects = units
        connect()
        if wasPlaying { play(rate: rate) }
    }

    /// The loudness step's gain, in dB, so the preview is as loud as the export.
    func setGain(_ decibels: Double) {
        gain.globalGain = Float(min(max(decibels, -96), 24))
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play(rate: Float = 1) {
        guard file != nil else { return }
        self.rate = rate
        speed.rate = rate
        if isPlaying { return }
        if time >= duration - 0.05 { time = 0 }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return
            }
        }
        schedule(from: time)
        node.play()
        isPlaying = true
        stoppedAt = nil
        startClock()
    }

    /// L: plays, or plays faster if already playing.
    func playFaster() {
        play(rate: isPlaying ? min(rate * 2, 2) : 1)
    }

    func pause() {
        guard isPlaying else {
            rate = 1
            return
        }
        time = min(position, duration)
        stopPlaying()
        rate = 1
        speed.rate = 1
    }

    func seek(to newTime: Double) {
        time = min(max(newTime, 0), duration)
        if isPlaying {
            schedule(from: time)
            node.play()
        }
    }

    func resetClip() {
        meter.clipped = false
    }

    // MARK: - Playing

    private func schedule(from seconds: Double) {
        guard let file else { return }
        generation += 1
        let current = generation
        node.stop()
        let start = min(AVAudioFramePosition(seconds * file.processingFormat.sampleRate), file.length)
        scheduledFrom = start
        let count = file.length - start
        guard count > 0 else { return }
        node.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(count), at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.reachedEnd(of: current) }
            }
        }
    }

    private func reachedEnd(of scheduled: Int) {
        guard scheduled == generation, isPlaying else { return }
        time = duration
        stopPlaying()
    }

    /// Where the player is in the file, in seconds.
    private var position: Double {
        guard let file, let rendered = node.lastRenderTime, let played = node.playerTime(forNodeTime: rendered) else { return time }
        let rate = file.processingFormat.sampleRate
        return (Double(scheduledFrom) + Double(max(played.sampleTime, 0))) / rate
    }

    private func stopPlaying() {
        generation += 1
        node.stop()
        isPlaying = false
        stoppedAt = Date()
    }

    // MARK: - Clock and meter

    private func startClock() {
        guard clock == nil else { return }
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The common mode keeps it running while a slider or the timeline is being dragged.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    private func tick() {
        if isPlaying {
            time = min(position, duration)
        }
        updateMeter()
        // After stopping, the meter falls back to silence, then the clock rests.
        if !isPlaying, let stoppedAt, Date().timeIntervalSince(stoppedAt) > 2 {
            clock?.invalidate()
            clock = nil
            var silent = MeterReading.silent
            silent.clipped = meter.clipped
            meter = silent
        }
    }

    private func updateMeter() {
        guard let levels else { return }
        let fresh = levels.take()
        let fall: Float = 26.0 / 30 // dB per tick: 26 dB a second, like a desk meter
        let now = Date()
        var reading = meter
        for channel in 0..<2 {
            let peak = channel < fresh.peak.count ? fresh.peak[channel] : -120
            let rms = channel < fresh.rms.count ? fresh.rms[channel] : -120
            reading.peak[channel] = max(peak, meter.peak[channel] - fall)
            reading.rms[channel] = max(rms, meter.rms[channel] - fall)
            if peak >= meter.hold[channel] {
                reading.hold[channel] = peak
                holdSince[channel] = now
            } else if now.timeIntervalSince(holdSince[channel]) > 1.5 {
                reading.hold[channel] = max(meter.hold[channel] - fall, reading.peak[channel])
            }
        }
        if fresh.clipped { reading.clipped = true }
        reading.momentary = fresh.momentary
        reading.shortTerm = fresh.shortTerm
        if reading != meter { meter = reading }
    }
}

/// Measures what comes out of the preview. The engine calls `measure` on its own thread; the clock calls `take`.
/// Loudness is K-weighted as BS.1770 describes, the same as the export's loudness step.
final class LevelTap: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleRate: Double
    private let channels: Int
    private var peaks: [Float]
    private var squares: [Double]
    private var frames = 0
    private var clipped = false
    private var setups: [vDSP_biquad_Setup]
    private var delays: [[Float]]
    /// K-weighted energy of recent blocks, summed over channels, and how many frames each covered.
    private var blocks: [(energy: Double, frames: Int)] = []
    private var weighted = [Float](repeating: 0, count: 8192)

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = max(channels, 1)
        peaks = Array(repeating: 0, count: max(channels, 1))
        squares = Array(repeating: 0, count: max(channels, 1))
        let sections = AudioProcessor.kWeighting(sampleRate: sampleRate)
        setups = (0..<max(channels, 1)).compactMap { _ in
            vDSP_biquad_CreateSetup(sections.flatMap { $0 }, vDSP_Length(sections.count))
        }
        delays = Array(repeating: Array(repeating: 0, count: 2 * sections.count + 2), count: max(channels, 1))
    }

    deinit {
        setups.forEach(vDSP_biquad_DestroySetup)
    }

    func measure(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }
        if weighted.count < count { weighted = [Float](repeating: 0, count: count) }
        lock.lock()
        defer { lock.unlock() }
        var energy = 0.0
        for channel in 0..<min(channels, Int(buffer.format.channelCount)) {
            let samples = data[channel]
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))
            peaks[channel] = max(peaks[channel], peak)
            if peak >= 1 { clipped = true }
            var sumOfSquares: Float = 0
            vDSP_svesq(samples, 1, &sumOfSquares, vDSP_Length(count))
            squares[channel] += Double(sumOfSquares)
            if channel < setups.count {
                vDSP_biquad(setups[channel], &delays[channel], samples, 1, &weighted, 1, vDSP_Length(count))
                var weightedSquares: Float = 0
                vDSP_svesq(weighted, 1, &weightedSquares, vDSP_Length(count))
                energy += Double(weightedSquares)
            }
        }
        frames += count
        blocks.append((energy, count))
        // Three seconds is the longest window the meter needs.
        var kept = 0
        var index = blocks.count
        while index > 0, Double(kept) < 3 * sampleRate {
            index -= 1
            kept += blocks[index].frames
        }
        if index > 0 { blocks.removeFirst(index) }
    }

    /// The levels since the last call, which starts the next measurement afresh.
    func take() -> (peak: [Float], rms: [Float], clipped: Bool, momentary: Double?, shortTerm: Double?) {
        lock.lock()
        defer {
            peaks = Array(repeating: 0, count: channels)
            squares = Array(repeating: 0, count: channels)
            frames = 0
            clipped = false
            lock.unlock()
        }
        func decibels(_ value: Double) -> Float { Float(20 * log10(max(value, 1e-6))) }
        let peak = peaks.map { decibels(Double($0)) }
        let rms = squares.map { frames > 0 ? decibels(sqrt($0 / Double(frames))) : -120 }
        return (peak, rms, clipped, loudness(over: 0.4), loudness(over: 3))
    }

    private func loudness(over seconds: Double) -> Double? {
        var energy = 0.0
        var counted = 0
        for block in blocks.reversed() where Double(counted) < seconds * sampleRate {
            energy += block.energy
            counted += block.frames
        }
        guard counted > 0, Double(counted) >= seconds * sampleRate * 0.9, energy > 0 else { return nil }
        let value = -0.691 + 10 * log10(energy / Double(counted))
        return value > -70 ? value : nil
    }
}
