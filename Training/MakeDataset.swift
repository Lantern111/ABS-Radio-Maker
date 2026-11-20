// Builds the training clips for the talk detector from the station's own recordings.
//
// Usage: make-dataset <recordings folder> <output folder>
//
// Nothing is labeled by hand. The labels come from what the recordings already say for certain:
//
// - The microphone is mono and background music is stereo, so where left and right are exactly equal, only the
//   microphone is on. Within those stretches, talking and the gaps between phrases are easy to tell apart by level.
// - Songs are where the built-in sound classifier is sure there's music and nobody talking.
//
// Background music is then mixed under the clean microphone on purpose, at many levels, so the detector learns to
// tell "talking over music" from "music in a pause". Each clip is a second long, 16 kHz mono, and labeled by what
// happens in its middle half-second. Three broadcasts are held out entirely, for testing.

import Accelerate
import AVFoundation
import Foundation

let heldOut: Set<String> = ["260518_왓츠인마이백 막방.wav", "R_20260903-170034.wav", "R_20261116-180121.wav"]
let rate = 16_000.0
let clipLength = 16_000
let levelHop = 320 // 20 ms

struct Recording {
    let name: String
    let left: [Float]
    let right: [Float]
    /// One flag per second: left and right identical.
    let monoSeconds: [Bool]
    let windows: [ClassifiedWindow]
}

var generator = SeededGenerator(seed: 2026)

func resampled(_ samples: [Float], from sourceRate: Double) -> [Float] {
    let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: source, to: target)!
    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count))!
    samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    input.frameLength = AVAudioFrameCount(samples.count)
    let capacity = AVAudioFrameCount(Double(samples.count) * rate / sourceRate) + 1024
    let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed {
            status.pointee = .endOfStream
            return nil
        }
        fed = true
        status.pointee = .haveData
        return input
    }
    return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
}

func load(_ url: URL) throws -> Recording {
    let clip = try AudioClip.load(from: url)
    let sourceRate = clip.sampleRate
    let second = Int(sourceRate)
    var mono = [Bool]()
    clip.channels[0].withUnsafeBufferPointer { left in
        clip.channels[1].withUnsafeBufferPointer { right in
            var start = 0
            while start + second <= clip.frameCount {
                mono.append(memcmp(left.baseAddress! + start, right.baseAddress! + start, second * 4) == 0)
                start += second
            }
        }
    }
    let windows = try ContentDetector.classify(clip)
    return Recording(
        name: url.lastPathComponent,
        left: resampled(clip.channels[0], from: sourceRate),
        right: resampled(clip.channels[1], from: sourceRate),
        monoSeconds: mono,
        windows: windows
    )
}

func levels(_ samples: [Float]) -> [Float] {
    stride(from: 0, to: samples.count - levelHop, by: levelHop).map { start in
        var meanSquare: Float = 0
        samples.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &meanSquare, vDSP_Length(levelHop)) }
        return 10 * log10(max(meanSquare, 1e-12))
    }
}

func rms(_ samples: ArraySlice<Float>) -> Float {
    var meanSquare: Float = 0
    Array(samples).withUnsafeBufferPointer { vDSP_measqv($0.baseAddress!, 1, &meanSquare, vDSP_Length($0.count)) }
    return sqrt(meanSquare)
}

/// A stretch with only the microphone on, its 20 ms levels, and the level that counts as talking.
struct CleanStretch {
    let start: Int // sample at 16 kHz
    let samples: ArraySlice<Float>
    let levels: [Float]
    let talkingLevel: Float
    let speechRMS: Float
}

func cleanStretches(in recording: Recording) -> [CleanStretch] {
    var stretches = [CleanStretch]()
    var second = 0
    while second < recording.monoSeconds.count {
        guard recording.monoSeconds[second] else {
            second += 1
            continue
        }
        var end = second
        while end < recording.monoSeconds.count, recording.monoSeconds[end] { end += 1 }
        if end - second >= 5 {
            let range = (second * Int(rate))..<min(end * Int(rate), recording.left.count)
            let samples = recording.left[range]
            let stretchLevels = levels(Array(samples))
            let sorted = stretchLevels.sorted()
            let loud = sorted[Int(Double(sorted.count - 1) * 0.9)]
            let quiet = sorted[Int(Double(sorted.count - 1) * 0.1)]
            // A real microphone stretch drops close to silence between phrases. A mono music bed wouldn't.
            if loud - quiet > 30 {
                let threshold = loud - 25
                let talking = zip(samples.indices.dropLast(levelHop).striding(levelHop), stretchLevels).filter { $0.1 >= threshold }
                var energy: Float = 0
                for (start, _) in talking { energy += pow(rms(samples[start..<start + levelHop]), 2) }
                let speechRMS = talking.isEmpty ? 0.05 : sqrt(energy / Float(talking.count))
                stretches.append(CleanStretch(start: range.lowerBound, samples: samples, levels: stretchLevels, talkingLevel: threshold, speechRMS: speechRMS))
            }
        }
        second = end
    }
    return stretches
}

extension Collection where Index == Int {
    func striding(_ step: Int) -> [Int] { Swift.stride(from: startIndex, to: endIndex, by: step).map { $0 } }
}

/// Song audio, mixed to mono, from stretches where the classifier is sure nobody is talking.
func songs(in recording: Recording) -> [ArraySlice<Float>] {
    let speech = ContentDetector.averaged(recording.windows.map(\.speech), reach: 3)
    var pieces = [ArraySlice<Float>]()
    var runStart: Double?
    var previous = 0.0
    for (index, window) in recording.windows.enumerated() {
        let isSong = speech[index] < 0.1 && max(window.music, window.singing) >= 0.5
        if isSong, runStart == nil { runStart = window.time }
        if !isSong || index == recording.windows.count - 1, let start = runStart {
            let end = isSong ? window.time : previous
            if end - start >= 4 {
                let range = Int((start + 1) * rate)..<min(Int(end * rate), recording.left.count)
                if !range.isEmpty {
                    var mixed = Array(recording.left[range])
                    let right = Array(recording.right[range])
                    for i in mixed.indices { mixed[i] = (mixed[i] + right[i]) / 2 }
                    pieces.append(mixed[...])
                }
            }
            runStart = nil
        }
        previous = window.time
    }
    return pieces
}

func randomMusic(_ pool: [ArraySlice<Float>]) -> ArraySlice<Float>? {
    let usable = pool.filter { $0.count > clipLength }
    guard let piece = usable.randomElement(using: &generator) else { return nil }
    let offset = Int.random(in: piece.startIndex...(piece.endIndex - clipLength), using: &generator)
    return piece[offset..<offset + clipLength]
}

func mix(_ voice: ArraySlice<Float>, music: ArraySlice<Float>?, musicDB: Float, speechRMS: Float) -> [Float] {
    var output = Array(voice)
    if let music {
        let musicRMS = max(rms(music), 1e-5)
        let gain = speechRMS * pow(10, musicDB / 20) / musicRMS
        for (i, sample) in music.enumerated() { output[i] += sample * gain }
    }
    // Overall level varies from broadcast to broadcast, so the detector shouldn't lean on it.
    let overall = pow(10, Float.random(in: -8...6, using: &generator) / 20)
    return output.map { min(max($0 * overall, -1), 1) }
}

var written = [String: Int]()

func write(_ samples: [Float], label: String, split: String, to folder: URL) throws {
    let directory = folder.appending(path: split).appending(path: label)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let key = "\(split)/\(label)"
    let index = written[key, default: 0]
    written[key] = index + 1
    let url = directory.appending(path: String(format: "%06d.wav", index))
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))!
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    try file.write(from: buffer)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: make-dataset <recordings folder> <output folder>") }
let folder = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])
try? FileManager.default.removeItem(at: output)

let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
    .filter { $0.pathExtension.lowercased() == "wav" && !$0.lastPathComponent.hasPrefix("._") }
    .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 50_000_000 }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

for url in files {
    let started = Date()
    let recording = try load(url)
    let split = heldOut.contains(recording.name) ? "test" : "train"
    let stretches = cleanStretches(in: recording)
    let music = songs(in: recording)

    // Candidate clips, by what happens in the middle half-second.
    var talking = [(CleanStretch, Int)]()
    var pauses = [(CleanStretch, Int)]()
    for stretch in stretches {
        let framesPerClip = clipLength / levelHop
        let middle = (framesPerClip / 4)..<(framesPerClip * 3 / 4)
        var frame = 0
        while frame + framesPerClip <= stretch.levels.count {
            let window = stretch.levels[frame..<frame + framesPerClip]
            let active = window.map { $0 >= stretch.talkingLevel }
            let middleActive = middle.filter { active[$0] }.count
            let allActive = active.filter { $0 }.count
            if Double(middleActive) / Double(middle.count) >= 0.6 {
                talking.append((stretch, frame * levelHop))
            } else if middleActive == 0, Double(allActive) / Double(framesPerClip) <= 0.15 {
                pauses.append((stretch, frame * levelHop))
            }
            frame += 12 // a quarter second
        }
    }
    talking.shuffle(using: &generator)
    pauses.shuffle(using: &generator)

    let perClass = 500
    var talkCount = 0
    for (stretch, offset) in talking.prefix(perClass) {
        let start = stretch.samples.startIndex + offset
        let voice = stretch.samples[start..<start + clipLength]
        let withMusic = Double.random(in: 0...1, using: &generator) < 0.7
        try write(
            mix(voice, music: withMusic ? randomMusic(music) : nil, musicDB: Float.random(in: -25 ... -3, using: &generator), speechRMS: stretch.speechRMS),
            label: "talk", split: split, to: output
        )
        talkCount += 1
    }
    // Pauses are fewer than talking, so each gets several different songs under it.
    var quietCount = 0
    var round = 0
    while quietCount < perClass * 7 / 10, !pauses.isEmpty, round < 6 {
        for (stretch, offset) in pauses where quietCount < perClass * 7 / 10 {
            let start = stretch.samples.startIndex + offset
            let voice = stretch.samples[start..<start + clipLength]
            let withMusic = round > 0 || Double.random(in: 0...1, using: &generator) < 0.85
            try write(
                mix(voice, music: withMusic ? randomMusic(music) : nil, musicDB: Float.random(in: -25 ... -3, using: &generator), speechRMS: stretch.speechRMS),
                label: "quiet", split: split, to: output
            )
            quietCount += 1
        }
        round += 1
    }
    // Songs on their own, singing included: singing isn't talking.
    for _ in 0..<(perClass * 3 / 10) {
        guard let piece = randomMusic(music) else { break }
        try write(mix(piece, music: nil, musicDB: 0, speechRMS: 1), label: "quiet", split: split, to: output)
        quietCount += 1
    }

    let clean = stretches.reduce(0) { $0 + $1.samples.count } / Int(rate)
    let songSeconds = music.reduce(0) { $0 + $1.count } / Int(rate)
    print(String(format: "%@ %@  clean mic %d s, songs %d s, candidates talk %d pause %d → wrote talk %d quiet %d  (%.0f s)",
                 split, recording.name, clean, songSeconds, talking.count, pauses.count, talkCount, quietCount, Date().timeIntervalSince(started)))
}
print(written.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "  "))
