import Accelerate
import AVFoundation
import Observation
import os

/// What the meter shows, in dBFS for the levels and LUFS for loudness.
struct MeterReading: Equatable, Sendable {
    var peak: [Float] = [-120, -120]
    var rms: [Float] = [-120, -120]
    /// The highest peak lately, held for a moment so it can be read.
    var hold: [Float] = [-120, -120]
    /// The highest peak since the readout was last clicked, as Logic Pro shows above its meters.
    var highest: Float = -120
    /// A sample reached full scale. Stays lit until clicked.
    var clipped = false
    /// Loudness over the last 0.4 seconds.
    var momentary: Double?
    /// Loudness over the last 3 seconds.
    var shortTerm: Double?

    static let silent = MeterReading()
}

/// The numbers under and above the meter. They change a few times a second at most, so the window around them doesn't
/// redraw with every meter frame.
struct MeterReadouts: Equatable {
    var highest: Float = -120
    var clipped = false
    var momentary: Double?
    var shortTerm: Double?
}

/// Something on screen that follows the meter or the spectrum while the preview plays. The player refreshes it on its
/// own clock, so it moves without SwiftUI working out the window again.
@MainActor protocol PlaybackDisplay: AnyObject {
    /// On screen and visible: hidden windows and windows behind others aren't refreshed.
    var isShowing: Bool { get }
    var showsSpectrum: Bool { get }
    func refresh()
}

/// An effect in the preview, and the stretches it works on.
struct PlayerInsert {
    let unit: AVAudioUnit
    let scope: InsertScope
}

/// Plays the cleaned-up recording through the EQ and plug-ins live, then the same loudness gain the export gets and a
/// limiter, so the preview sounds like the finished video and settings can be heard as they change. The picture and
/// the timeline follow `time`. The meter and spectrum are drawn by `PlaybackDisplay`s the player refreshes itself.
@MainActor @Observable final class PreviewPlayer {
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    /// Where playback is, in seconds. Updated 30 times a second while playing. Not observed: what shows it is a
    /// `PlaybackDisplay`, refreshed on the player's clock and whenever playback jumps, so the rest of the window
    /// isn't worked out again with every frame.
    @ObservationIgnored private(set) var time: Double = 0 {
        didSet {
            if time != oldValue, !isTicking { refreshDisplays() }
        }
    }
    @ObservationIgnored private var isTicking = false
    /// 1 is normal speed. Pressing L again while playing doubles it, up to 2.
    private(set) var rate: Float = 1
    private(set) var readouts = MeterReadouts()
    @ObservationIgnored private(set) var meter = MeterReading.silent
    @ObservationIgnored let spectrum = SpectrumAnalyzer()
    @ObservationIgnored private var displays: [WeakDisplay] = []
    @ObservationIgnored private var ticks = 0

    private struct WeakDisplay {
        weak var display: (any PlaybackDisplay)?
    }

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
    @ObservationIgnored private var inserts: [PlayerInsert] = []
    /// For effects that only work on talk or only on songs: the effect and the untouched sound side by side, each
    /// turned up and down as the stretches change.
    @ObservationIgnored private var blends: [Blend] = []
    @ObservationIgnored private var envelope = ScopeEnvelope()
    @ObservationIgnored private var file: AVAudioFile?
    /// The frame of the file the current playback was scheduled from.
    @ObservationIgnored private var scheduledFrom: AVAudioFramePosition = 0
    /// Goes up with every new schedule, so a finished-playing message from an old one is ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private let output = OutputTap()
    @ObservationIgnored private var holdSince: [Date] = [.distantPast, .distantPast]
    @ObservationIgnored private var stoppedAt: Date?

    private struct Blend {
        let scope: InsertScope
        let wet: AVAudioMixerNode
        let dry: AVAudioMixerNode
        let sum: AVAudioMixerNode
        /// Holds the untouched sound back by as much as the effects do, so the two line up.
        let delay: AVAudioUnitDelay?

        var nodes: [AVAudioNode] { [wet, dry, sum] + (delay.map { [$0] } ?? []) }
    }

    init() {
        engine.attach(node)
        engine.attach(speed)
        engine.attach(gain)
        engine.attach(limiter)
        // The meter and the spectrum listen to what comes out of the limiter, block by block as it's played, which
        // is smoother than a tap: taps only hand over a tenth of a second at a time.
        AudioUnitAddRenderNotify(limiter.audioUnit, outputRenderNotify, Unmanaged.passUnretained(output).toOpaque())
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

    var sampleRate: Double { format.sampleRate }

    /// Player → speed → EQ and plug-ins → loudness gain → limiter → output, with the meter listening at the end.
    private func connect() {
        let old: [AVAudioNode] = [node, speed] + inserts.map(\.unit) + blends.flatMap(\.nodes) + [gain, limiter]
        for item in old { engine.disconnectNodeOutput(item) }
        for blend in blends { blend.nodes.forEach(engine.detach) }
        blends = []

        let format = format
        engine.connect(node, to: speed, format: format)
        var last: AVAudioNode = speed
        for group in InsertScope.groups(inserts, scope: \.scope) {
            let units = group.items.map(\.unit)
            guard group.scope != .everything else {
                for unit in units {
                    engine.connect(last, to: unit, format: format)
                    last = unit
                }
                continue
            }
            let blend = makeBlend(scope: group.scope, latency: units.reduce(0) { $0 + $1.auAudioUnit.latency })
            blend.nodes.forEach(engine.attach)
            // The sound splits: one side through the effects, the other untouched.
            let dryInput: AVAudioNode = blend.delay ?? blend.dry
            engine.connect(last, to: [
                AVAudioConnectionPoint(node: units[0], bus: 0),
                AVAudioConnectionPoint(node: dryInput, bus: 0),
            ], fromBus: 0, format: format)
            for (from, to) in zip(units, units.dropFirst()) {
                engine.connect(from, to: to, format: format)
            }
            engine.connect(units.last!, to: blend.wet, format: format)
            if let delay = blend.delay {
                engine.connect(delay, to: blend.dry, format: format)
            }
            engine.connect(blend.wet, to: blend.sum, fromBus: 0, toBus: 0, format: format)
            engine.connect(blend.dry, to: blend.sum, fromBus: 0, toBus: 1, format: format)
            blends.append(blend)
            last = blend.sum
        }
        engine.connect(last, to: gain, format: format)
        engine.connect(gain, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        applyBlends(at: time)
        output.configure(sampleRate: format.sampleRate, channels: Int(format.channelCount))
    }

    private func makeBlend(scope: InsertScope, latency: TimeInterval) -> Blend {
        var delay: AVAudioUnitDelay?
        if latency > 0 {
            let unit = AVAudioUnitDelay()
            unit.delayTime = min(latency, 2)
            unit.feedback = 0
            unit.wetDryMix = 100
            unit.lowPassCutoff = Float(format.sampleRate / 2)
            delay = unit
        }
        return Blend(scope: scope, wet: AVAudioMixerNode(), dry: AVAudioMixerNode(), sum: AVAudioMixerNode(), delay: delay)
    }

    /// Turns each effect that only works on some stretches up or down for a moment of the recording.
    private func applyBlends(at time: Double) {
        for blend in blends {
            let amount = envelope.amount(for: blend.scope, at: time)
            if blend.wet.outputVolume != amount {
                blend.wet.outputVolume = amount
                blend.dry.outputVolume = 1 - amount
            }
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

    /// The EQ and plug-ins that play live, in order. Playback carries on where it was.
    func setInserts(_ new: [PlayerInsert]) {
        let same = new.count == inserts.count && zip(new, inserts).allSatisfy { $0.unit === $1.unit && $0.scope == $1.scope }
        guard !same else { return }
        let wasPlaying = isPlaying
        let playingRate = rate
        if wasPlaying { pause() }
        for old in inserts where !new.contains(where: { $0.unit === old.unit }) {
            engine.detach(old.unit)
        }
        for insert in new where !inserts.contains(where: { $0.unit === insert.unit }) {
            engine.attach(insert.unit)
        }
        inserts = new
        connect()
        if wasPlaying { play(rate: playingRate) }
    }

    /// Where talk and songs are, in the preview's time, and how long the fade between them is.
    func setEnvelope(_ envelope: ScopeEnvelope) {
        self.envelope = envelope
        applyBlends(at: time)
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
        applyBlends(at: time)
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
        applyBlends(at: time)
        if isPlaying {
            schedule(from: time)
            node.play()
        }
    }

    func resetClip() {
        meter.clipped = false
        meter.highest = -120
        updateReadouts(force: true)
    }

    func addDisplay(_ display: any PlaybackDisplay) {
        displays.removeAll { $0.display == nil || $0.display === display }
        displays.append(WeakDisplay(display: display))
        display.refresh()
    }

    func removeDisplay(_ display: any PlaybackDisplay) {
        displays.removeAll { $0.display == nil || $0.display === display }
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

    // MARK: - Clock, meter, and spectrum

    private func startClock() {
        guard clock == nil else { return }
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The common mode keeps it running while a slider or the timeline is being dragged.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    private func refreshDisplays() {
        for display in displays.compactMap(\.display) where display.isShowing {
            display.refresh()
        }
    }

    private func tick() {
        isTicking = true
        defer { isTicking = false }
        if isPlaying {
            time = min(position, duration)
            applyBlends(at: time)
        }
        updateMeter()
        let showing = displays.compactMap(\.display).filter(\.isShowing)
        if showing.contains(where: \.showsSpectrum) {
            spectrum.update(from: output, sampleRate: format.sampleRate)
        }
        // After stopping, the meter and spectrum fall back to silence, then the clock rests.
        if !isPlaying, let stoppedAt, Date().timeIntervalSince(stoppedAt) > 2 {
            clock?.invalidate()
            clock = nil
            var silent = MeterReading.silent
            silent.clipped = meter.clipped
            silent.highest = meter.highest
            meter = silent
            spectrum.clear()
            updateReadouts(force: true)
        }
        for display in showing { display.refresh() }
    }

    /// The readouts follow the meter five times a second, and at once when the highest peak or the clip light changes.
    private func updateReadouts(force: Bool = false) {
        func tenths(_ value: Double?) -> Double? { value.map { ($0 * 10).rounded() / 10 } }
        let fresh = MeterReadouts(
            highest: (meter.highest * 10).rounded() / 10,
            clipped: meter.clipped,
            momentary: tenths(meter.momentary),
            shortTerm: tenths(meter.shortTerm)
        )
        guard fresh != readouts else { return }
        let urgent = fresh.highest != readouts.highest || fresh.clipped != readouts.clipped
        if force || urgent || ticks % 6 == 0 { readouts = fresh }
    }

    private func updateMeter() {
        let fresh = output.takeLevels()
        let fall: Float = 26.0 / 30 // dB per tick: 26 dB a second, like a desk meter
        let now = Date()
        var reading = meter
        for channel in 0..<2 {
            let peak = channel < fresh.peak.count ? fresh.peak[channel] : -120
            let rms = channel < fresh.rms.count ? fresh.rms[channel] : -120
            reading.peak[channel] = max(peak, meter.peak[channel] - fall)
            reading.rms[channel] = max(rms, meter.rms[channel] - fall)
            reading.highest = max(reading.highest, peak)
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
        meter = reading
        ticks += 1
        updateReadouts()
    }
}

/// Called by the limiter on the audio thread after each block it plays.
private func outputRenderNotify(
    _ refCon: UnsafeMutableRawPointer,
    _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ timeStamp: UnsafePointer<AudioTimeStamp>,
    _ bus: UInt32,
    _ frames: UInt32,
    _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    guard flags.pointee.contains(.unitRenderAction_PostRender),
          !flags.pointee.contains(.unitRenderAction_PostRenderError),
          bus == 0, let data
    else { return noErr }
    let tap = Unmanaged<OutputTap>.fromOpaque(refCon).takeUnretainedValue()
    tap.receive(UnsafeMutableAudioBufferListPointer(data), frames: Int(frames))
    return noErr
}

/// What the preview plays, as it plays: levels for the meter and the latest stretch of sound for the spectrum. The
/// audio thread hands blocks to `receive`; the clock reads them on the main thread.
final class OutputTap: @unchecked Sendable {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var levels: LevelTap
    /// The last `ringSize` samples, left and right together, for the spectrum.
    private let ring: UnsafeMutablePointer<Float>
    private var written = 0
    static let ringSize = 32_768

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        levels = LevelTap(sampleRate: 44_100, channels: 2)
        ring = .allocate(capacity: Self.ringSize)
        ring.initialize(repeating: 0, count: Self.ringSize)
    }

    deinit {
        lock.deallocate()
        ring.deallocate()
    }

    func configure(sampleRate: Double, channels: Int) {
        let fresh = LevelTap(sampleRate: sampleRate, channels: channels)
        os_unfair_lock_lock(lock)
        let old = levels
        levels = fresh
        os_unfair_lock_unlock(lock)
        _ = old
    }

    func receive(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, buffers.count > 0 else { return }
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        levels.measure(buffers, frames: frames)
        // Left and right are averaged, as a spectrum meter does.
        guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let interleaved = Int(buffers[0].mNumberChannels) > 1
        let right: UnsafeMutablePointer<Float>
        let stride: Int
        if interleaved {
            right = left + 1
            stride = Int(buffers[0].mNumberChannels)
        } else {
            right = (buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? left
            stride = 1
        }
        let mask = Self.ringSize - 1
        var position = written & mask
        for index in 0..<frames {
            ring[position] = (left[index * stride] + right[index * stride]) * 0.5
            position = (position + 1) & mask
        }
        written += frames
    }

    func takeLevels() -> LevelTap.Reading {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return levels.take()
    }

    /// Copies the latest `count` samples, oldest first.
    func latest(_ count: Int, into destination: UnsafeMutablePointer<Float>) {
        let count = min(count, Self.ringSize)
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let mask = Self.ringSize - 1
        let start = (written - count) & mask
        let first = min(count, Self.ringSize - start)
        destination.update(from: ring + start, count: first)
        if first < count {
            (destination + first).update(from: ring, count: count - first)
        }
    }
}

/// Measures what comes out of the preview. Loudness is K-weighted as BS.1770 describes, the same as the export's
/// loudness step. Not safe across threads by itself: `OutputTap` holds a lock around it.
final class LevelTap {
    struct Reading {
        var peak: [Float]
        var rms: [Float]
        var clipped: Bool
        var momentary: Double?
        var shortTerm: Double?
    }

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
    private var weighted = [Float](repeating: 0, count: 16_384)

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
        // Blocks come a few hundred samples at a time; three seconds of them fit without growing on the audio thread.
        blocks.reserveCapacity(4096)
    }

    deinit {
        setups.forEach(vDSP_biquad_DestroySetup)
    }

    func measure(_ buffers: UnsafeMutableAudioBufferListPointer, frames count: Int) {
        let count = min(count, weighted.count)
        guard count > 0 else { return }
        var energy = 0.0
        for channel in 0..<channels {
            // Each channel in a buffer of its own, or side by side in one.
            let samples: UnsafeMutablePointer<Float>
            let stride: Int
            if buffers.count == 1, Int(buffers[0].mNumberChannels) > channel {
                guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                samples = data + channel
                stride = Int(buffers[0].mNumberChannels)
            } else if channel < buffers.count, let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) {
                samples = data
                stride = 1
            } else {
                continue
            }
            var peak: Float = 0
            vDSP_maxmgv(samples, stride, &peak, vDSP_Length(count))
            peaks[channel] = max(peaks[channel], peak)
            if peak >= 1 { clipped = true }
            var sumOfSquares: Float = 0
            vDSP_svesq(samples, stride, &sumOfSquares, vDSP_Length(count))
            squares[channel] += Double(sumOfSquares)
            if channel < setups.count {
                weighted.withUnsafeMutableBufferPointer { weighted in
                    vDSP_biquad(setups[channel], &delays[channel], samples, stride, weighted.baseAddress!, 1, vDSP_Length(count))
                    var weightedSquares: Float = 0
                    vDSP_svesq(weighted.baseAddress!, 1, &weightedSquares, vDSP_Length(count))
                    energy += Double(weightedSquares)
                }
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
    func take() -> Reading {
        defer {
            for channel in 0..<channels {
                peaks[channel] = 0
                squares[channel] = 0
            }
            frames = 0
            clipped = false
        }
        func decibels(_ value: Double) -> Float { Float(20 * log10(max(value, 1e-6))) }
        let peak = peaks.map { decibels(Double($0)) }
        let rms = squares.map { frames > 0 ? decibels(sqrt($0 / Double(frames))) : -120 }
        return Reading(peak: peak, rms: rms, clipped: clipped, momentary: loudness(over: 0.4), shortTerm: loudness(over: 3))
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
