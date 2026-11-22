// Checks the talk detector the way the app uses it, on broadcasts it never trained on.
//
// Usage: evaluate <TalkDetector.mlmodel> <dataset folder> <recordings folder>
//
// 1. Clips: how many of the held-out test clips it labels right.
// 2. Mouth: microphone-only stretches of the held-out broadcasts get one of their own songs mixed underneath, at a few
//    levels. The mouth worked out from the clean microphone is the answer key; the mouth worked out from the mix is
//    then checked against it, once gated by the built-in classifier (as before) and once by the talk detector.

import Accelerate
import AVFoundation
import CoreML
import Foundation
import SoundAnalysis

let heldOut = ["260518_왓츠인마이백 막방.wav", "R_20260903-170034.wav", "R_20261116-180121.wav"]
let arguments = CommandLine.arguments
guard arguments.count == 4 else { fatalError("Usage: evaluate <model> <dataset folder> <recordings folder>") }
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: arguments[1]))
let model = try TalkDetector.loadModel(at: compiled)
let dataset = URL(fileURLWithPath: arguments[2])
let recordings = URL(fileURLWithPath: arguments[3])

// MARK: - Clips

final class TopLabel: NSObject, SNResultsObserving {
    var talk: Double?
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard talk == nil, let result = result as? SNClassificationResult else { return }
        talk = result.classification(forIdentifier: "talk")?.confidence
    }
}

for label in ["talk", "quiet"] {
    let folder = dataset.appending(path: "test").appending(path: label)
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
    var right = 0
    for file in files {
        let analyzer = try SNAudioFileAnalyzer(url: file)
        let request = try SNClassifySoundRequest(mlModel: model)
        let observer = TopLabel()
        try analyzer.add(request, withObserver: observer)
        analyzer.analyze()
        if ((observer.talk ?? 0) >= 0.5) == (label == "talk") { right += 1 }
    }
    print(String(format: "test clips %@: %.1f%% right (%d of %d)", label, Double(right) / Double(files.count) * 100, right, files.count))
}

// MARK: - Mouth

let fps = 30
func mouth(_ clip: AudioClip, talking: TalkTimeline?) -> [UInt8] {
    let processed = ProcessedAudio(clip: clip, timeMap: TimeMap(pieces: [.init(sourceStart: 0, outputStart: 0, length: clip.duration)]), loudnessBefore: nil, gain: 0)
    return Performance.make(
        audio: processed,
        voiceLevels: Performance.voiceLevels(clip, framesPerSecond: fps),
        sourceSegments: [ContentSegment(start: 0, end: clip.duration, isMusic: false)],
        talking: talking,
        framesPerSecond: fps,
        mouthSensitivity: 0.5,
        listeningEyes: .open
    ).mouth
}

struct Tally {
    var falseOpen = 0, shut = 0, missed = 0, open = 0
    /// Frames inside real pauses, where the clean microphone keeps the mouth shut for half a second or more.
    var pauseFrames = 0, pauseOpen = 0
    mutating func add(answer: [UInt8], guess: [UInt8]) {
        var run = 0
        for i in 0...min(answer.count, guess.count) {
            if i < min(answer.count, guess.count), answer[i] == 0 {
                run += 1
                continue
            }
            if run >= fps / 2 {
                for j in (i - run)..<i {
                    pauseFrames += 1
                    if guess[j] > 0 { pauseOpen += 1 }
                }
            }
            run = 0
        }
        for i in 0..<min(answer.count, guess.count) {
            if answer[i] > 0 {
                open += 1
                if guess[i] == 0 { missed += 1 }
            } else {
                shut += 1
                if guess[i] > 0 { falseOpen += 1 }
            }
        }
    }
    var summary: String {
        String(format: "moves during pauses %5.1f%%   opens when it shouldn't %5.1f%%   stays shut when it should open %5.1f%%",
               Double(pauseOpen) / Double(max(pauseFrames, 1)) * 100,
               Double(falseOpen) / Double(max(shut, 1)) * 100, Double(missed) / Double(max(open, 1)) * 100)
    }
}

var tallies = [String: Tally]()
let levels: [Float] = [-18, -12, -6]
// How the app smooths the detector's answers (TalkTimeline), plus any others worth comparing.
let variants: [(Int, Double)] = [(1, 0.65)]
for name in heldOut {
    let clip = try AudioClip.load(from: recordings.appending(path: name))
    let rate = clip.sampleRate
    let second = Int(rate)
    // Microphone-only stretches of at least 30 seconds.
    var stretches = [Range<Int>]()
    var start: Int?
    var position = 0
    clip.channels[0].withUnsafeBufferPointer { left in
        clip.channels[1].withUnsafeBufferPointer { right in
            while position + second <= clip.frameCount {
                let mono = memcmp(left.baseAddress! + position, right.baseAddress! + position, second * 4) == 0
                if mono, start == nil { start = position }
                if !mono, let begun = start {
                    if position - begun >= 30 * second { stretches.append(begun..<position) }
                    start = nil
                }
                position += second
            }
        }
    }
    // Songs from the same broadcast, for the music underneath.
    let windows = try ContentDetector.classify(clip)
    let songs = ContentDetector.segments(from: windows, duration: clip.duration).filter { $0.isMusic && $0.end - $0.start > 70 }
    guard !songs.isEmpty else { continue }

    for (index, stretch) in stretches.prefix(3).enumerated() {
        let length = min(stretch.count, 60 * second)
        let voice = Array(clip.channels[0][stretch.lowerBound..<stretch.lowerBound + length])
        let song = songs[index % songs.count]
        let songStart = Int((song.start + 5) * rate)
        let musicLeft = Array(clip.channels[0][songStart..<songStart + length])
        let musicRight = Array(clip.channels[1][songStart..<songStart + length])
        let answer = mouth(AudioClip(channels: [voice, voice], sampleRate: rate), talking: nil)
        var speechRMS: Float = 0
        vDSP_rmsqv(voice, 1, &speechRMS, vDSP_Length(voice.count))
        var musicRMS: Float = 0
        vDSP_rmsqv(musicLeft, 1, &musicRMS, vDSP_Length(musicLeft.count))
        for level in levels {
            let gain = speechRMS * pow(10, level / 20) / max(musicRMS, 1e-5)
            var left = voice
            var right = voice
            for i in 0..<length {
                left[i] += musicLeft[i] * gain
                right[i] += musicRight[i] * gain
            }
            let mix = AudioClip(channels: [left, right], sampleRate: rate)
            let builtIn = mouth(mix, talking: TalkTimeline(windows: try ContentDetector.classify(mix)))
            let moments = try TalkDetector.detect(mix, model: model)
            tallies["\(Int(level)) built-in", default: Tally()].add(answer: answer, guess: builtIn)
            for (reach, threshold) in variants {
                var timeline = TalkTimeline(moments: moments)
                timeline.reach = reach
                timeline.threshold = threshold
                tallies["\(Int(level)) trained r\(reach) t\(threshold)", default: Tally()].add(answer: answer, guess: mouth(mix, talking: timeline))
            }
        }
    }
    print("checked", name, "–", min(stretches.count, 3), "stretches")
}
for level in levels {
    let kinds = ["built-in"] + variants.map { "trained r\($0.0) t\($0.1)" }
    for kind in kinds {
        if let tally = tallies["\(Int(level)) \(kind)"] {
            print(String(format: "BGM %+3.0f dB  %@  %@", level, kind.padding(toLength: 18, withPad: " ", startingAt: 0), tally.summary))
        }
    }
}
