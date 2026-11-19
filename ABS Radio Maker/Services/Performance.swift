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
    /// Talk and song stretches in the edited audio's time, for the timeline.
    var segments: [ContentSegment]

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
            segments: [ContentSegment(start: 0, end: seconds, isMusic: false)]
        )
    }

    static func make(
        audio: ProcessedAudio,
        sourceSegments: [ContentSegment],
        framesPerSecond: Int,
        mouthSensitivity: Double
    ) -> Performance {
        let clip = audio.clip
        let fps = Double(framesPerSecond)
        let count = max(1, Int((clip.duration * fps).rounded(.up)))

        // Song or talk for each frame, looked up in the original recording's time.
        var isMusic = [Bool](repeating: false, count: count)
        if !sourceSegments.isEmpty {
            var segmentIndex = 0
            for frame in 0..<count {
                let time = audio.timeMap.sourceTime(at: (Double(frame) + 0.5) / fps)
                // Times only move forward, except for a jump back at a shortened pause, which is rare enough to search.
                if time < sourceSegments[segmentIndex].start { segmentIndex = 0 }
                while segmentIndex < sourceSegments.count - 1, sourceSegments[segmentIndex].end <= time { segmentIndex += 1 }
                isMusic[frame] = sourceSegments[segmentIndex].isMusic
            }
        }

        let levels = frameLevels(clip, frameCount: count, framesPerSecond: fps)
        let talkLevels = zip(levels, isMusic).filter { !$0.1 }.map(\.0).sorted()
        func percentile(_ fraction: Double) -> Float {
            talkLevels.isEmpty ? -40 : talkLevels[Int(Double(talkLevels.count - 1) * min(max(fraction, 0), 1))]
        }
        // Thresholds come from this recording's own talk, so a quiet or heavily compressed recording still gets about
        // the same mix of shut, half-open, and wide-open frames.
        let halfQuantile = 0.45 - 0.3 * mouthSensitivity
        let halfOpen = percentile(halfQuantile)
        let wideOpen = max(percentile(halfQuantile + 0.32), halfOpen + 3)
        let floor = percentile(0.2)
        let peak = max(percentile(0.97), floor + 6)

        var mouth = [UInt8](repeating: 0, count: count)
        var energy = [Float](repeating: 0, count: count)
        var smoothedEnergy: Float = 0
        for frame in 0..<count where !isMusic[frame] {
            mouth[frame] = levels[frame] >= wideOpen ? 2 : levels[frame] >= halfOpen ? 1 : 0
            let level = min(max((levels[frame] - floor) / (peak - floor), 0), 1)
            smoothedEnergy += (level - smoothedEnergy) * (level > smoothedEnergy ? 0.5 : 0.08)
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

        var segments = [ContentSegment]()
        for frame in 0..<count {
            let time = Double(frame) / fps
            if let last = segments.last, last.isMusic == isMusic[frame] {
                segments[segments.count - 1].end = time + 1 / fps
            } else {
                segments.append(ContentSegment(start: time, end: time + 1 / fps, isMusic: isMusic[frame]))
            }
        }

        return Performance(
            framesPerSecond: framesPerSecond,
            mouth: mouth,
            energy: energy,
            listening: listening,
            blinking: blinks(count: count, framesPerSecond: framesPerSecond),
            segments: segments
        )
    }

    /// The loudest channel's level in each frame, in dB.
    static func frameLevels(_ clip: AudioClip, frameCount: Int, framesPerSecond: Double) -> [Float] {
        var levels = [Float](repeating: -120, count: frameCount)
        for channel in clip.channels {
            channel.withUnsafeBufferPointer { samples in
                for frame in 0..<frameCount {
                    let start = Int(Double(frame) / framesPerSecond * clip.sampleRate)
                    let end = min(Int(Double(frame + 1) / framesPerSecond * clip.sampleRate), samples.count)
                    guard end > start else { continue }
                    var meanSquare: Float = 0
                    vDSP_measqv(samples.baseAddress! + start, 1, &meanSquare, vDSP_Length(end - start))
                    levels[frame] = max(levels[frame], 10 * log10(max(meanSquare, 1e-12)))
                }
            }
        }
        return levels
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
        let energy = Double(frameCount > 0 ? self.energy[frame] : 0)
        let listening = Double(frameCount > 0 ? self.listening[frame] : 0)
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
            drawing = .listening
        } else if frameCount > 0, blinking[frame] {
            drawing = .blink
        } else {
            switch frameCount > 0 ? mouth[frame] : 0 {
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
