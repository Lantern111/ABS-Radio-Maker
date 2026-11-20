import Accelerate
import AVFoundation
import SoundAnalysis

/// A stretch of the recording that is either talk or a song.
struct ContentSegment: Sendable, Equatable {
    var start: Double
    var end: Double
    var isMusic: Bool
}

/// How sure the classifier is about what it heard in one window of the recording.
struct ClassifiedWindow: Sendable {
    var time: Double
    var speech: Double
    var music: Double
    var singing: Double
}

/// Finds where songs play, with the sound classifier built into macOS, so no model ships with the app.
enum ContentDetector {
    static func classify(_ clip: AudioClip, progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> [ClassifiedWindow] {
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 2, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        let observer = Observer()
        try analyze(clip, request: request, observer: observer, progress: progress, isCancelled: isCancelled)
        return observer.windows.sorted { $0.time < $1.time }
    }

    /// Feeds a clip, mixed to mono a second at a time, through a sound analysis request.
    static func analyze(
        _ clip: AudioClip,
        request: SNRequest,
        observer: SNResultsObserving,
        progress: (Double) -> Void,
        isCancelled: () -> Bool
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: clip.sampleRate, channels: 1) else {
            throw AudioClipError.cannotCreateBuffer
        }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: observer)

        let chunk = Int(clip.sampleRate) // one second at a time
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw AudioClipError.cannotCreateBuffer
        }
        var scale = 1 / Float(clip.channels.count)
        var position = 0
        while position < clip.frameCount {
            if isCancelled() { throw CancellationError() }
            let count = min(chunk, clip.frameCount - position)
            let output = buffer.floatChannelData![0]
            output.update(repeating: 0, count: count)
            for channel in clip.channels {
                channel.withUnsafeBufferPointer { samples in
                    // output += samples * scale
                    vDSP_vsma(samples.baseAddress! + position, 1, &scale, output, 1, output, 1, vDSP_Length(count))
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            analyzer.analyze(buffer, atAudioFramePosition: AVAudioFramePosition(position))
            position += count
            progress(Double(position) / Double(clip.frameCount))
        }
        analyzer.completeAnalysis()
    }

    /// Turns the classifier's guesses into steady stretches, so the character doesn't flip between talking and
    /// listening every few seconds.
    static func segments(from windows: [ClassifiedWindow], duration: Double) -> [ContentSegment] {
        guard !windows.isEmpty, duration > 0 else {
            return [ContentSegment(start: 0, end: max(duration, 0), isMusic: false)]
        }

        // A song: music or singing with nobody talking. While a vocal is loud the classifier's music score can drop low,
        // but its speech score stays near zero, so speech is what tells talk from song.
        //
        // Talking over background music only scores about 0.2 to 0.5 for speech in any one window, against under 0.15
        // for a song, so the score is averaged over about seven seconds first. A DJ talking over BGM or over a song's
        // intro or ending counts as talk, because that's when the mouth should move.
        let reach = 3
        let speech = averaged(windows.map(\.speech), reach: reach)
        var isMusic = windows.indices.map { index in
            speech[index] < 0.25 && max(windows[index].music, windows[index].singing) >= 0.4
        }

        // Majority vote over about seven seconds smooths out single odd windows.
        isMusic = isMusic.indices.map { index in
            let neighbors = isMusic[max(0, index - reach)...min(isMusic.count - 1, index + reach)]
            return neighbors.filter { $0 }.count * 2 > neighbors.count
        }

        var segments = [ContentSegment]()
        for (index, window) in windows.enumerated() {
            let start = index == 0 ? 0 : (windows[index - 1].time + window.time) / 2
            let end = index == windows.count - 1 ? duration : (window.time + windows[index + 1].time) / 2
            if let last = segments.last, last.isMusic == isMusic[index] {
                segments[segments.count - 1].end = end
            } else {
                segments.append(ContentSegment(start: start, end: end, isMusic: isMusic[index]))
            }
        }

        // Songs shorter than 20 seconds are jingles or stings: the character keeps talking through them. Then short talk
        // between two songs, like a word over a crossfade, joins the songs.
        segments = merging(segments) { $0.isMusic && $0.end - $0.start < 20 }
        segments = merging(segments) { !$0.isMusic && $0.end - $0.start < 4 }
        return segments
    }

    /// Second look at the talk stretches with the trained talk detector, which hears the announcers far better than
    /// the built-in classifier. A stretch where they hardly talk was a song all along: a sung or rapped verse, a jingle.
    ///
    /// - A stretch where the detector hears talking less than a fifth of the time is a song, however long.
    /// - One shorter than a minute with talking under 30% of the time is too.
    /// - So is one under a minute with talking 30–55% of the time, if it's mixed like a song: the sides within 10 dB of
    ///   the middle. A song's vocal comes with stereo reverb, while the announcer's mono microphone over background
    ///   music, which is turned down, leaves the sides 11–13 dB under the middle.
    static func refine(_ segments: [ContentSegment], talk moments: [TalkDetector.Moment], clip: AudioClip) -> [ContentSegment] {
        guard !moments.isEmpty else { return segments }
        var refined = segments.map { segment -> ContentSegment in
            guard !segment.isMusic else { return segment }
            let inside = moments.filter { $0.time >= segment.start && $0.time < segment.end }
            guard !inside.isEmpty else { return segment }
            let density = Double(inside.filter { $0.talk >= 0.65 }.count) / Double(inside.count)
            let length = segment.end - segment.start
            var isSong = density < 0.2 || length < 60 && density < 0.3
            if !isSong, length < 60, density < 0.55, sideToMiddle(clip, from: segment.start, to: segment.end) >= -10 {
                isSong = true
            }
            return ContentSegment(start: segment.start, end: segment.end, isMusic: isSong)
        }
        refined = merging(refined) { _ in false }
        return refined
    }

    /// How loud the difference between left and right is, against their sum, in the voice band, in dB. Minus infinity
    /// for mono.
    static func sideToMiddle(_ clip: AudioClip, from start: Double, to end: Double) -> Double {
        guard clip.channels.count >= 2 else { return -.infinity }
        let range = max(0, Int(start * clip.sampleRate))..<min(clip.frameCount, Int(end * clip.sampleRate))
        guard range.count > 1000 else { return -.infinity }
        var middle = [Float](repeating: 0, count: range.count)
        var side = [Float](repeating: 0, count: range.count)
        clip.channels[0].withUnsafeBufferPointer { left in
            clip.channels[1].withUnsafeBufferPointer { right in
                for (index, frame) in range.enumerated() {
                    middle[index] = (left[frame] + right[frame]) / 2
                    side[index] = (left[frame] - right[frame]) / 2
                }
            }
        }
        let band = [
            AudioProcessor.highPassCoefficients(frequency: 300, q: 0.7071, sampleRate: clip.sampleRate),
            AudioProcessor.lowPassCoefficients(frequency: 3400, q: 0.7071, sampleRate: clip.sampleRate),
        ]
        AudioProcessor.filter(&middle, sections: band)
        AudioProcessor.filter(&side, sections: band)
        var middleSquare: Float = 0
        var sideSquare: Float = 0
        vDSP_measqv(middle, 1, &middleSquare, vDSP_Length(middle.count))
        vDSP_measqv(side, 1, &sideSquare, vDSP_Length(side.count))
        guard sideSquare > 0 else { return -.infinity }
        return 10 * log10(Double(sideSquare) / Double(max(middleSquare, 1e-20)))
    }

    /// Each value replaced by the average of itself and its neighbors within `reach`.
    static func averaged(_ values: [Double], reach: Int) -> [Double] {
        values.indices.map { index in
            let neighbors = values[max(0, index - reach)...min(values.count - 1, index + reach)]
            return neighbors.reduce(0, +) / Double(neighbors.count)
        }
    }

    /// How sure the classifier is that someone is talking at a moment, averaged over a few seconds. The windows must be
    /// sorted by time.
    static func speech(at time: Double, in windows: [ClassifiedWindow]) -> Double {
        guard !windows.isEmpty else { return 1 }
        var low = 0
        var high = windows.count - 1
        while low < high {
            let middle = (low + high) / 2
            if windows[middle].time < time { low = middle + 1 } else { high = middle }
        }
        let neighbors = windows[max(0, low - 1)...min(windows.count - 1, low + 1)]
        return neighbors.reduce(0) { $0 + $1.speech } / Double(neighbors.count)
    }

    /// Flips each segment the rule picks to the other kind, and joins neighbors of the same kind.
    private static func merging(_ segments: [ContentSegment], flipping rule: (ContentSegment) -> Bool) -> [ContentSegment] {
        var result = [ContentSegment]()
        for var segment in segments {
            if segments.count > 1, rule(segment) {
                segment.isMusic.toggle()
            }
            if let last = result.last, last.isMusic == segment.isMusic {
                result[result.count - 1].end = segment.end
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private final class Observer: NSObject, SNResultsObserving {
        private let lock = NSLock()
        private var collected = [ClassifiedWindow]()

        var windows: [ClassifiedWindow] {
            lock.withLock { collected }
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            func confidence(_ label: String) -> Double {
                result.classification(forIdentifier: label)?.confidence ?? 0
            }
            let window = ClassifiedWindow(
                time: result.timeRange.start.seconds + result.timeRange.duration.seconds / 2,
                speech: confidence("speech"),
                music: confidence("music"),
                singing: max(confidence("singing"), confidence("rapping"), confidence("humming"))
            )
            lock.withLock { collected.append(window) }
        }
    }
}
