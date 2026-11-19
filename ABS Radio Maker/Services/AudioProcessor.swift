import Accelerate
import Foundation

/// Connects times in the edited audio to times in the original recording, which differ once the start is trimmed or
/// pauses are shortened.
struct TimeMap: Sendable {
    /// A stretch of the original that was kept, which plays from `outputStart` in the edited audio.
    struct Piece: Sendable {
        var sourceStart: Double
        var outputStart: Double
        var length: Double
    }

    var pieces: [Piece]

    var outputDuration: Double { pieces.last.map { $0.outputStart + $0.length } ?? 0 }

    func sourceTime(at outputTime: Double) -> Double {
        guard !pieces.isEmpty else { return outputTime }
        var low = 0
        var high = pieces.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if pieces[middle].outputStart <= outputTime { low = middle } else { high = middle - 1 }
        }
        let piece = pieces[low]
        return piece.sourceStart + min(max(outputTime - piece.outputStart, 0), piece.length)
    }

    /// Where a time in the original recording plays in the edited audio. A time that was cut out lands where the
    /// audio picks up again.
    func outputTime(atSource sourceTime: Double) -> Double {
        guard let first = pieces.first else { return sourceTime }
        if sourceTime <= first.sourceStart { return 0 }
        for piece in pieces {
            if sourceTime < piece.sourceStart { return piece.outputStart }
            if sourceTime <= piece.sourceStart + piece.length { return piece.outputStart + sourceTime - piece.sourceStart }
        }
        return outputDuration
    }
}

struct ProcessedAudio: Sendable {
    var clip: AudioClip
    var timeMap: TimeMap
    /// Loudness of the kept part before it was evened out, in LUFS. Nil when it's too quiet to measure.
    var loudnessBefore: Double?
}

/// Applies the edits in AudioEditOptions to a recording.
enum AudioProcessor {
    /// The frames of the original recording that the trim points keep.
    static func keptFrames(frameCount: Int, sampleRate rate: Double, options: AudioEditOptions) -> Range<Int> {
        var start = Int((options.trimStart * rate).rounded())
        var end = options.trimEnd.map { Int(($0 * rate).rounded()) } ?? frameCount
        start = min(max(start, 0), frameCount)
        end = min(max(end, start), frameCount)
        if end - start < Int(rate) {
            // Less than a second left means the trim points crossed. Keep everything rather than nothing.
            return 0..<frameCount
        }
        return start..<end
    }

    static func process(_ source: AudioClip, options: AudioEditOptions, progress: (Double) -> Void = { _ in }) -> ProcessedAudio {
        let kept = keptFrames(frameCount: source.frameCount, sampleRate: source.sampleRate, options: options)
        let trimmed = AudioClip(channels: source.channels.map { Array($0[kept]) }, sampleRate: source.sampleRate)
        return process(trimmed: trimmed, startingAt: kept.lowerBound, options: options, progress: progress)
    }

    static func process(_ source: SourceAudio, options: AudioEditOptions, progress: (Double) -> Void = { _ in }) -> ProcessedAudio {
        let kept = keptFrames(frameCount: source.frameCount, sampleRate: source.sampleRate, options: options)
        return process(trimmed: source.clip(kept), startingAt: kept.lowerBound, options: options, progress: progress)
    }

    /// Edits audio that's already been trimmed. `start` is where it begins in the original recording, in frames.
    ///
    /// The clip is consumed so its samples are edited where they are. Copying them first would hold a second copy of a
    /// whole show, over half a gigabyte, for as long as the edit takes.
    static func process(trimmed: consuming AudioClip, startingAt start: Int, options: AudioEditOptions, progress: (Double) -> Void) -> ProcessedAudio {
        let rate = trimmed.sampleRate
        let end = start + trimmed.frameCount
        var channels = (consume trimmed).channels
        progress(0.1)

        if options.removesRumble {
            let coefficients = highPassCoefficients(frequency: 80, q: 0.7071, sampleRate: rate)
            for index in channels.indices {
                filter(&channels[index], sections: [coefficients])
            }
        }
        progress(0.3)

        var pieces = [TimeMap.Piece(sourceStart: Double(start) / rate, outputStart: 0, length: Double(end - start) / rate)]
        if options.shortensSilences {
            let kept = keptRangesAfterShorteningSilences(channels, sampleRate: rate)
            if kept.count > 1 {
                channels = channels.map { channel in
                    var joined = [Float]()
                    joined.reserveCapacity(kept.reduce(0) { $0 + $1.count })
                    for range in kept { joined.append(contentsOf: channel[range]) }
                    return joined
                }
                var outputFrame = 0
                pieces = kept.map { range in
                    defer { outputFrame += range.count }
                    return TimeMap.Piece(
                        sourceStart: Double(start + range.lowerBound) / rate,
                        outputStart: Double(outputFrame) / rate,
                        length: Double(range.count) / rate
                    )
                }
                smoothJoins(&channels, at: pieces.dropFirst().map { Int(($0.outputStart * rate).rounded()) }, sampleRate: rate)
            }
        }
        progress(0.5)

        let before = integratedLoudness(channels, sampleRate: rate)
        progress(0.7)
        if options.normalizesLoudness, let before {
            var gain = Float(pow(10, (options.targetLoudness - before) / 20))
            for index in channels.indices {
                channels[index].withUnsafeMutableBufferPointer { samples in
                    vDSP_vsmul(samples.baseAddress!, 1, &gain, samples.baseAddress!, 1, vDSP_Length(samples.count))
                }
            }
        }
        limit(&channels, ceiling: pow(10, -1 / 20), sampleRate: rate)
        progress(0.9)

        applyFades(&channels, fadeIn: options.fadeIn, fadeOut: options.fadeOut, sampleRate: rate)
        progress(1)

        return ProcessedAudio(clip: AudioClip(channels: channels, sampleRate: rate), timeMap: TimeMap(pieces: pieces), loudnessBefore: before)
    }

    // MARK: - Filters

    /// Biquad coefficients in vDSP's order: b0, b1, b2, a1, a2, all divided by a0.
    typealias Biquad = [Double]

    static func highPassCoefficients(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        return [(1 + cosine) / 2 / a0, -(1 + cosine) / a0, (1 + cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0]
    }

    static func lowPassCoefficients(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let omega = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2 * q)
        let cosine = cos(omega)
        let a0 = 1 + alpha
        return [(1 - cosine) / 2 / a0, (1 - cosine) / a0, (1 - cosine) / 2 / a0, -2 * cosine / a0, (1 - alpha) / a0]
    }

    /// Runs the samples through the filter sections in place, a piece at a time so it needs little extra memory.
    static func filter(_ samples: inout [Float], sections: [Biquad]) {
        guard let setup = vDSP_biquad_CreateSetup(sections.flatMap { $0 }, vDSP_Length(sections.count)) else { return }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * sections.count + 2)
        let chunk = 1 << 16
        var output = [Float](repeating: 0, count: chunk)
        samples.withUnsafeMutableBufferPointer { samples in
            var position = 0
            while position < samples.count {
                let count = min(chunk, samples.count - position)
                vDSP_biquad(setup, &delay, samples.baseAddress! + position, 1, &output, 1, vDSP_Length(count))
                (samples.baseAddress! + position).update(from: output, count: count)
                position += count
            }
        }
    }

    // MARK: - Loudness (ITU-R BS.1770)

    /// The K-weighting filter loudness meters hear through, worked out for any sample rate.
    static func kWeighting(sampleRate: Double) -> [Biquad] {
        let shelfGain = 3.999843853973347
        let shelfQ = 0.7071752369554196
        let shelfFrequency = 1681.974450955533
        var k = tan(Double.pi * shelfFrequency / sampleRate)
        let vh = pow(10, shelfGain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / shelfQ + k * k
        let shelf = [
            (vh + vb * k / shelfQ + k * k) / a0,
            2 * (k * k - vh) / a0,
            (vh - vb * k / shelfQ + k * k) / a0,
            2 * (k * k - 1) / a0,
            (1 - k / shelfQ + k * k) / a0,
        ]

        let passQ = 0.5003270373238773
        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        a0 = 1 + k / passQ + k * k
        let highPass = [1, -2, 1, 2 * (k * k - 1) / a0, (1 - k / passQ + k * k) / a0]
        return [shelf, highPass]
    }

    /// Integrated loudness in LUFS, gated the way BS.1770-4 describes. Nil for silence.
    static func integratedLoudness(_ channels: [[Float]], sampleRate: Double) -> Double? {
        let step = Int(sampleRate / 10) // 100 ms; a 400 ms block is four of these
        guard let frameCount = channels.first?.count, frameCount >= step * 4 else { return nil }
        let stepCount = frameCount / step
        var stepEnergy = [Double](repeating: 0, count: stepCount)

        let sections = kWeighting(sampleRate: sampleRate)
        for channel in channels {
            guard let setup = vDSP_biquad_CreateSetup(sections.flatMap { $0 }, vDSP_Length(sections.count)) else { continue }
            var delay = [Float](repeating: 0, count: 2 * sections.count + 2)
            var filtered = [Float](repeating: 0, count: step)
            channel.withUnsafeBufferPointer { samples in
                for index in 0..<stepCount {
                    vDSP_biquad(setup, &delay, samples.baseAddress! + index * step, 1, &filtered, 1, vDSP_Length(step))
                    var sum: Float = 0
                    vDSP_svesq(filtered, 1, &sum, vDSP_Length(step))
                    stepEnergy[index] += Double(sum)
                }
            }
            vDSP_biquad_DestroySetup(setup)
        }

        let blockLength = Double(step * 4)
        var blocks = [Double]()
        blocks.reserveCapacity(stepCount)
        if stepCount >= 4 {
            for index in 0...(stepCount - 4) {
                blocks.append((stepEnergy[index] + stepEnergy[index + 1] + stepEnergy[index + 2] + stepEnergy[index + 3]) / blockLength)
            }
        }
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }

        let aboveAbsolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return nil }
        let relativeGate = loudness(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { loudness($0) > relativeGate }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }

    // MARK: - Peak limiter

    /// Turns the level down just enough, just before each peak, to keep every sample under the ceiling, then lets it
    /// come back up over about 80 ms. Gain is worked out for blocks of 32 samples and ramped between them.
    static func limit(_ channels: inout [[Float]], ceiling: Float, sampleRate: Double) {
        guard let frameCount = channels.first?.count, frameCount > 0 else { return }
        let blockSize = 32
        let blockCount = (frameCount + blockSize - 1) / blockSize

        var needed = [Float](repeating: 1, count: blockCount)
        var anyOver = false
        for channel in channels {
            channel.withUnsafeBufferPointer { samples in
                for block in 0..<blockCount {
                    let start = block * blockSize
                    let count = min(blockSize, frameCount - start)
                    var peak: Float = 0
                    vDSP_maxmgv(samples.baseAddress! + start, 1, &peak, vDSP_Length(count))
                    if peak > ceiling {
                        needed[block] = min(needed[block], ceiling / peak)
                        anyOver = true
                    }
                }
            }
        }
        guard anyOver else { return }

        // Reach: how many blocks ahead the gain starts to fall. About 5 ms.
        let reach = max(2, Int((0.005 * sampleRate / Double(blockSize)).rounded(.up)))
        var lowest = [Float](repeating: 1, count: blockCount)
        for block in 0..<blockCount where needed[block] < 1 {
            for neighbor in max(0, block - reach)...min(blockCount - 1, block + reach) {
                lowest[neighbor] = min(lowest[neighbor], needed[block])
            }
        }
        // Averaging over fewer blocks than the reach keeps every block's gain at or below what it needs.
        let span = reach - 1
        var running = [Double](repeating: 0, count: blockCount + 1)
        for block in 0..<blockCount { running[block + 1] = running[block] + Double(lowest[block]) }
        var gain = [Float](repeating: 1, count: blockCount + 1)
        let release = Float(1 - exp(-Double(blockSize) / sampleRate / 0.08))
        var previous: Float = 1
        for block in 0..<blockCount {
            let low = max(0, block - span)
            let high = min(blockCount - 1, block + span)
            let smoothed = Float((running[high + 1] - running[low]) / Double(high - low + 1))
            previous = min(smoothed, previous + (1 - previous) * release)
            gain[block] = previous
        }
        gain[blockCount] = gain[blockCount - 1]

        for index in channels.indices {
            channels[index].withUnsafeMutableBufferPointer { samples in
                for block in 0..<blockCount where gain[block] < 1 || gain[block + 1] < 1 {
                    let start = block * blockSize
                    let count = min(blockSize, frameCount - start)
                    var level = gain[block]
                    var increment = (gain[block + 1] - gain[block]) / Float(blockSize)
                    let pointer = samples.baseAddress! + start
                    vDSP_vrampmul(pointer, 1, &level, &increment, pointer, 1, vDSP_Length(count))
                }
            }
        }
    }

    // MARK: - Silences

    /// The parts to keep when every pause longer than 1.5 seconds is cut down to half a second.
    static func keptRangesAfterShorteningSilences(_ channels: [[Float]], sampleRate: Double) -> [Range<Int>] {
        guard let frameCount = channels.first?.count else { return [] }
        let hop = Int(sampleRate / 100) // 10 ms
        let hopCount = frameCount / hop
        guard hopCount > 0 else { return [0..<frameCount] }

        var levels = [Float](repeating: -120, count: hopCount)
        for channel in channels {
            channel.withUnsafeBufferPointer { samples in
                for index in 0..<hopCount {
                    var meanSquare: Float = 0
                    vDSP_measqv(samples.baseAddress! + index * hop, 1, &meanSquare, vDSP_Length(hop))
                    levels[index] = max(levels[index], 10 * log10(max(meanSquare, 1e-12)))
                }
            }
        }
        // Quiet means well under the loud parts of the recording, so it works for quiet and loud recordings alike.
        let loud = levels.sorted()[Int(Double(hopCount - 1) * 0.95)]
        let threshold = max(loud - 35, -65)

        let longest = 150 // hops: a pause longer than 1.5 s gets shortened
        let keepEachSide = 25 // hops: 0.25 s of the pause stays on each side
        var kept = [Range<Int>]()
        var keepStart = 0
        var index = 0
        while index < hopCount {
            guard levels[index] < threshold else {
                index += 1
                continue
            }
            var runEnd = index
            while runEnd < hopCount, levels[runEnd] < threshold { runEnd += 1 }
            if runEnd - index > longest {
                let cutStart = (index + keepEachSide) * hop
                let cutEnd = (runEnd - keepEachSide) * hop
                kept.append(keepStart..<cutStart)
                keepStart = cutEnd
            }
            index = runEnd
        }
        kept.append(keepStart..<frameCount)
        return kept.filter { !$0.isEmpty }
    }

    /// Fades a few milliseconds around each place two kept parts meet, so the join can't click.
    static func smoothJoins(_ channels: inout [[Float]], at joins: [Int], sampleRate: Double) {
        let length = Int(sampleRate * 0.005)
        for index in channels.indices {
            let count = channels[index].count
            for join in joins {
                for offset in 0..<length {
                    let gain = Float(offset) / Float(length)
                    if join - 1 - offset >= 0 { channels[index][join - 1 - offset] *= gain }
                    if join + offset < count { channels[index][join + offset] *= gain }
                }
            }
        }
    }

    static func applyFades(_ channels: inout [[Float]], fadeIn: Double, fadeOut: Double, sampleRate: Double) {
        guard let frameCount = channels.first?.count, frameCount > 0 else { return }
        let inLength = min(Int(fadeIn * sampleRate), frameCount / 2)
        let outLength = min(Int(fadeOut * sampleRate), frameCount / 2)
        for index in channels.indices {
            channels[index].withUnsafeMutableBufferPointer { samples in
                if inLength > 0 {
                    var level: Float = 0
                    var increment = 1 / Float(inLength)
                    vDSP_vrampmul(samples.baseAddress!, 1, &level, &increment, samples.baseAddress!, 1, vDSP_Length(inLength))
                }
                if outLength > 0 {
                    var level: Float = 1
                    var increment = -1 / Float(outLength)
                    let pointer = samples.baseAddress! + (frameCount - outLength)
                    vDSP_vrampmul(pointer, 1, &level, &increment, pointer, 1, vDSP_Length(outLength))
                }
            }
        }
    }
}
