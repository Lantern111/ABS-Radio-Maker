import Accelerate
import Foundation

/// Everything the character does in the video, worked out frame by frame before anything is drawn: when the mouth
/// opens, when it blinks, how lively it is, and when it's listening to a song.
struct Performance: Sendable {
    var framesPerSecond: Int
    /// 0 closed, 1 a little open, 2 wide open.
    var mouth: [UInt8]
    /// How loud the talking is right now, from 0 to 1, smoothed. Makes the character move a little more.
    var energy: [Float]
    /// How far into the listening pose, from 0 to 1. Eases over half a second when a song starts or stops.
    var listening: [Float]
    var blinking: [Bool]
    /// While listening, whether the eyes are shut to enjoy the song.
    var eyesClosed: [Bool]

    var frameCount: Int { mouth.count }
    var duration: Double { Double(frameCount) / Double(framesPerSecond) }

    /// A character that just sits and breathes, for arranging the layers before a recording is open.
    static func idle(seconds: Double = 12, framesPerSecond: Int) -> Performance {
        let count = Int(seconds * Double(framesPerSecond))
        return Performance(
            framesPerSecond: framesPerSecond,
            mouth: Array(repeating: 0, count: count),
            energy: Array(repeating: 0, count: count),
            listening: Array(repeating: 0, count: count),
            blinking: blinks(count: count, framesPerSecond: framesPerSecond),
            eyesClosed: Array(repeating: false, count: count)
        )
    }

    /// - Parameters:
    ///   - voiceLevels: From `voiceLevels(_:framesPerSecond:)`, at the same frame rate.
    ///   - sourceSegments: Talk and songs, in the original recording's time.
    ///   - speechWindows: The classifier's results, in the original recording's time, so the mouth stays shut where
    ///     nobody is talking even though something else is playing.
    static func make(
        audio: ProcessedAudio,
        voiceLevels levels: [Float],
        sourceSegments: [ContentSegment],
        speechWindows: [ClassifiedWindow],
        framesPerSecond: Int,
        mouthSensitivity: Double,
        listeningEyes: ListeningEyes
    ) -> Performance {
        let fps = Double(framesPerSecond)
        let count = max(1, levels.count)
        let sourceTimes = (0..<count).map { audio.timeMap.sourceTime(at: (Double($0) + 0.5) / fps) }

        // Song or talk for each frame, looked up in the original recording's time.
        var isMusic = [Bool](repeating: false, count: count)
        if !sourceSegments.isEmpty {
            var segmentIndex = 0
            for frame in 0..<count {
                let time = sourceTimes[frame]
                // Times only move forward, except for a jump back at a shortened pause, which is rare enough to search.
                if time < sourceSegments[segmentIndex].start { segmentIndex = 0 }
                while segmentIndex < sourceSegments.count - 1, sourceSegments[segmentIndex].end <= time { segmentIndex += 1 }
                isMusic[frame] = sourceSegments[segmentIndex].isMusic
            }
        }

        // The mouth follows the voice compared with the last moment or so, not with the whole show, so background music
        // under the talking doesn't hold it open: each syllable rises above the music bed for a moment, then drops back.
        let reach = max(1, Int(0.6 * fps))
        let localLow = slidingExtreme(levels, reach: reach, lowest: true)
        let localHigh = slidingExtreme(levels, reach: reach, lowest: false)
        let halfOpen = Float(0.6 - 0.3 * mouthSensitivity)
        let wideOpen = halfOpen + 0.35

        var mouth = [UInt8](repeating: 0, count: count)
        var energy = [Float](repeating: 0, count: count)
        var smoothedEnergy: Float = 0
        for frame in 0..<count where levels.indices.contains(frame) && !isMusic[frame] {
            let range = localHigh[frame] - localLow[frame]
            let level = range < 8 ? 0 : (levels[frame] - localLow[frame]) / range
            let someoneIsTalking = speechWindows.isEmpty
                || ContentDetector.speech(at: sourceTimes[frame], in: speechWindows) >= 0.3
            if someoneIsTalking {
                mouth[frame] = level >= wideOpen ? 2 : level >= halfOpen ? 1 : 0
            }
            let target: Float = someoneIsTalking ? level : 0
            smoothedEnergy += (target - smoothedEnergy) * (target > smoothedEnergy ? 0.5 : 0.08)
            energy[frame] = smoothedEnergy
        }
        // Lips pass through half open on the way from wide open to shut, and a single shut frame in the middle of
        // speech reads as flicker, so it stays half open.
        for frame in 1..<max(1, count - 1) where mouth[frame] == 0 {
            if mouth[frame - 1] == 2 || mouth[frame - 1] > 0 && mouth[frame + 1] > 0 {
                mouth[frame] = 1
            }
        }

        var listening = [Float](repeating: 0, count: count)
        var amount: Float = 0
        let step = Float(1 / (0.5 * fps))
        for frame in 0..<count {
            amount = isMusic[frame] ? min(1, amount + step) : max(0, amount - step)
            listening[frame] = amount
        }

        return Performance(
            framesPerSecond: framesPerSecond,
            mouth: mouth,
            energy: energy,
            listening: listening,
            blinking: blinks(count: count, framesPerSecond: framesPerSecond),
            eyesClosed: eyesClosed(isMusic: isMusic, framesPerSecond: framesPerSecond, style: listeningEyes)
        )
    }

    /// How loud the voice band (300 to 3,400 Hz) is in each frame, in dB. Bass and cymbals from music matter less here.
    static func voiceLevels(_ clip: AudioClip, framesPerSecond: Int) -> [Float] {
        let fps = Double(framesPerSecond)
        let frameCount = max(1, Int((clip.duration * fps).rounded(.up)))
        let sections = [
            AudioProcessor.highPassCoefficients(frequency: 300, q: 0.7071, sampleRate: clip.sampleRate),
            AudioProcessor.lowPassCoefficients(frequency: 3400, q: 0.7071, sampleRate: clip.sampleRate),
        ]
        guard let setup = vDSP_biquad_CreateSetup(sections.flatMap { $0 }, vDSP_Length(sections.count)) else {
            return Array(repeating: -120, count: frameCount)
        }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delay = [Float](repeating: 0, count: 2 * sections.count + 2)

        let longest = Int((clip.sampleRate / fps).rounded(.up)) + 1
        var mixed = [Float](repeating: 0, count: longest)
        var filtered = [Float](repeating: 0, count: longest)
        var scale = 1 / Float(max(clip.channels.count, 1))
        var levels = [Float](repeating: -120, count: frameCount)
        for frame in 0..<frameCount {
            let start = Int(Double(frame) / fps * clip.sampleRate)
            let end = min(Int(Double(frame + 1) / fps * clip.sampleRate), clip.frameCount)
            let length = min(end - start, longest)
            guard length > 0 else { continue }
            vDSP_vclr(&mixed, 1, vDSP_Length(length))
            for channel in clip.channels {
                channel.withUnsafeBufferPointer { samples in
                    vDSP_vsma(samples.baseAddress! + start, 1, &scale, mixed, 1, &mixed, 1, vDSP_Length(length))
                }
            }
            vDSP_biquad(setup, &delay, mixed, 1, &filtered, 1, vDSP_Length(length))
            var meanSquare: Float = 0
            vDSP_measqv(filtered, 1, &meanSquare, vDSP_Length(length))
            levels[frame] = 10 * log10(max(meanSquare, 1e-12))
        }
        return levels
    }

    /// The lowest or highest value within `reach` of each position.
    static func slidingExtreme(_ values: [Float], reach: Int, lowest: Bool) -> [Float] {
        values.indices.map { index in
            let neighbors = values[max(0, index - reach)...min(values.count - 1, index + reach)]
            return (lowest ? neighbors.min() : neighbors.max()) ?? values[index]
        }
    }

    /// Blinks every 2.5 to 6 seconds, each about an eighth of a second. The same every time, so a re-export matches.
    static func blinks(count: Int, framesPerSecond: Int) -> [Bool] {
        var generator = SeededGenerator(seed: 0xAB5)
        var blinking = [Bool](repeating: false, count: count)
        let fps = Double(framesPerSecond)
        let length = max(2, Int((0.13 * fps).rounded()))
        var next = Int(Double.random(in: 1.5...3.5, using: &generator) * fps)
        while next < count {
            for frame in next..<min(next + length, count) { blinking[frame] = true }
            next += Int(Double.random(in: 2.5...6, using: &generator) * fps)
        }
        return blinking
    }

    /// During songs, stretches with the eyes shut, between stretches of listening with them open.
    static func eyesClosed(isMusic: [Bool], framesPerSecond: Int, style: ListeningEyes) -> [Bool] {
        var closed = [Bool](repeating: false, count: isMusic.count)
        guard style != .open else { return closed }
        var generator = SeededGenerator(seed: 0x50A6)
        let fps = Double(framesPerSecond)
        var frame = 0
        while frame < isMusic.count {
            guard isMusic[frame] else {
                frame += 1
                continue
            }
            var songEnd = frame
            while songEnd < isMusic.count, isMusic[songEnd] { songEnd += 1 }
            if style == .always {
                for index in frame..<songEnd { closed[index] = true }
            } else {
                // Each song starts with the eyes open, then alternates.
                var position = frame + Int(Double.random(in: style.openSeconds, using: &generator) * fps)
                while position < songEnd {
                    let shut = Int(Double.random(in: style.closedSeconds, using: &generator) * fps)
                    for index in position..<min(position + shut, songEnd) { closed[index] = true }
                    position += shut + Int(Double.random(in: style.openSeconds, using: &generator) * fps)
                }
            }
            frame = songEnd
        }
        return closed
    }

    // MARK: - One frame

    struct Pose: Sendable {
        var drawing: LayerSlot
        /// Radians, around the bottom of the character.
        var rotation: Double
        /// Points to move by on a 1080-point-tall screen. Positive is down.
        var lift: Double
        var listening: Double
    }

    func pose(at frame: Int, swayAmount: Double) -> Pose {
        let frame = min(max(frame, 0), max(frameCount - 1, 0))
        let time = Double(frame) / Double(framesPerSecond)
        let hasFrames = frameCount > 0
        let energy = Double(hasFrames ? self.energy[frame] : 0)
        let listening = Double(hasFrames ? self.listening[frame] : 0)
        let degree = Double.pi / 180
        let sway = swayAmount

        let talkRotation = sway * degree * (
            0.6 * sin(2 * .pi * time / 4.7)
                + 0.25 * sin(2 * .pi * time / 1.9 + 1.3)
                + 0.5 * energy * sin(2 * .pi * time / 0.8)
        )
        let talkLift = sway * (2.5 * sin(2 * .pi * time / 3.3) - 5 * energy)
        let listenRotation = sway * degree * 2.2 * sin(2 * .pi * time / 2.4)
        let listenLift = -sway * 5 * abs(sin(.pi * time / 1.2))

        let drawing: LayerSlot
        if listening > 0.5 {
            if hasFrames, eyesClosed[frame] {
                drawing = .listening
            } else {
                drawing = hasFrames && blinking[frame] ? .blink : .character
            }
        } else if hasFrames, blinking[frame] {
            drawing = .blink
        } else {
            switch hasFrames ? mouth[frame] : 0 {
            case 2: drawing = .mouthOpen
            case 1: drawing = .mouthHalf
            default: drawing = .character
            }
        }

        return Pose(
            drawing: drawing,
            rotation: talkRotation + (listenRotation - talkRotation) * listening,
            lift: talkLift + (listenLift - talkLift) * listening,
            listening: listening
        )
    }
}

/// A small random number generator that gives the same numbers for the same seed (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
