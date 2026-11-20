import AVFoundation
import CoreML
import SoundAnalysis

/// When someone is talking, moment by moment, for deciding when the mouth may move.
struct TalkTimeline: Sendable {
    /// Moments in the original recording's time, sorted, each with how sure the detector is that someone is talking.
    var times: [Double]
    var confidence: [Double]
    /// How many neighbors on each side are averaged in, to steady the answer.
    var reach: Int
    var threshold: Double

    /// From the talk detector trained on the station's broadcasts: four answers a second. A moment counts as talking
    /// when it and its neighbors average 0.65; checked on held-out broadcasts, that keeps the mouth still in pauses over
    /// loud background music about six times better than before, while barely delaying the start of a sentence.
    init(moments: [TalkDetector.Moment]) {
        times = moments.map(\.time)
        confidence = moments.map(\.talk)
        reach = 1
        threshold = 0.65
    }

    /// From the built-in sound classifier, when the trained detector isn't available: one answer a second, and less
    /// sure of itself over background music.
    init(windows: [ClassifiedWindow]) {
        times = windows.map(\.time)
        confidence = windows.map(\.speech)
        reach = 1
        threshold = 0.3
    }

    func isTalking(at time: Double) -> Bool {
        guard !times.isEmpty else { return true }
        var low = 0
        var high = times.count - 1
        while low < high {
            let middle = (low + high) / 2
            if times[middle] < time { low = middle + 1 } else { high = middle }
        }
        let neighbors = confidence[max(0, low - reach)...min(confidence.count - 1, low + reach)]
        return neighbors.reduce(0, +) / Double(neighbors.count) >= threshold
    }
}

/// Finds when the announcer is talking with a small model trained on the station's own broadcasts (see Training/).
/// Unlike the built-in classifier, it learned to tell talking over background music from music in a pause.
enum TalkDetector {
    struct Moment: Sendable {
        var time: Double
        var talk: Double
    }

    /// The compiled model inside the app, or nil when the app was built without it.
    static let bundledModel: URL? = Bundle.main.url(forResource: "TalkDetectorModel", withExtension: "mlmodelc")

    static func loadModel(at url: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    /// Four answers a second: one-second windows, a quarter second apart.
    static func detect(
        _ clip: AudioClip,
        model: MLModel,
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> [Moment] {
        let request = try SNClassifySoundRequest(mlModel: model)
        let window = request.windowDuration.seconds
        request.overlapFactor = max(0, 1 - 0.25 / window)
        let observer = Observer()
        try ContentDetector.analyze(clip, request: request, observer: observer, progress: progress, isCancelled: isCancelled)
        return observer.moments.sorted { $0.time < $1.time }
    }

    private final class Observer: NSObject, SNResultsObserving {
        private let lock = NSLock()
        private var collected = [Moment]()

        var moments: [Moment] {
            lock.withLock { collected }
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let moment = Moment(
                time: result.timeRange.start.seconds + result.timeRange.duration.seconds / 2,
                talk: result.classification(forIdentifier: "talk")?.confidence ?? 0
            )
            lock.withLock { collected.append(moment) }
        }
    }
}
