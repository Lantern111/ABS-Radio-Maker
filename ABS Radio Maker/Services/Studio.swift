import Accelerate
import AppKit
import Observation
import UniformTypeIdentifiers

/// Everything about the recording being worked on: the sound, its edits, what the character does, and the export.
@MainActor @Observable final class Studio {
    enum Phase: Equatable {
        case empty
        case working(message: String, fraction: Double?)
        case ready
    }

    struct ExportState: Equatable {
        var fraction: Double = 0
        var message = "준비하는 중…"
        var finishedURL: URL?
        var errorMessage: String?
    }

    let layers = LayerLibrary()
    let player = PreviewPlayer()

    var settings = StudioSettings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.framesPerSecond != oldValue.framesPerSecond
                || settings.mouthSensitivity != oldValue.mouthSensitivity
                || settings.listeningEyes != oldValue.listeningEyes {
                rebuildPerformance()
            }
        }
    }

    var audioOptions = AudioEditOptions.load() {
        didSet {
            guard audioOptions != oldValue else { return }
            audioOptions.save()
            scheduleProcessing()
        }
    }

    private(set) var phase = Phase.empty
    private(set) var recordingURL: URL?
    private(set) var recordingDuration: Double = 0
    private(set) var processed: ProcessedAudio?
    private(set) var performance: Performance
    /// Song and talk stretches in the original recording's time.
    private(set) var sourceSegments: [ContentSegment] = []
    private(set) var segmentsWereEdited = false
    /// Peak levels for drawing the timeline, from 0 to 1, `peaksPerSecond` of them for each second of edited audio.
    private(set) var peaks: [Float] = []
    nonisolated static let peaksPerSecond = 100.0
    var export: ExportState?
    var errorMessage: String?

    @ObservationIgnored private var source: AudioClip?
    @ObservationIgnored private var detectedSegments: [ContentSegment] = []
    @ObservationIgnored private var classifiedWindows: [ClassifiedWindow] = []
    /// Voice levels for each frame of the edited audio, and the frame rate they were measured at.
    @ObservationIgnored private var voiceLevels: (levels: [Float], framesPerSecond: Int)?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var exportCancel = CancelFlag()
    @ObservationIgnored private var previewRenderer: FrameRenderer?
    @ObservationIgnored private var previewRendererRevision = -1

    static let audioTypes: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]

    init() {
        let settings = StudioSettings.load()
        performance = Performance.idle(framesPerSecond: settings.framesPerSecond)
    }

    var hasRecording: Bool { processed != nil }

    var isBusy: Bool {
        if case .working = phase { return true }
        return export != nil && export?.finishedURL == nil && export?.errorMessage == nil
    }

    // MARK: - Opening

    func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.message = "영상으로 만들 녹음 파일을 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        processingTask?.cancel()
        player.unload()
        // Cleared first, so resetting the trim below doesn't start processing the previous recording.
        source = nil
        processed = nil
        peaks = []
        voiceLevels = nil
        performance = Performance.idle(framesPerSecond: settings.framesPerSecond)
        recordingURL = url
        recordingDuration = 0
        audioOptions.trimStart = 0
        audioOptions.trimEnd = nil
        phase = .working(message: "녹음 파일을 읽는 중…", fraction: 0)

        processingTask = Task { [weak self] in
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let clip = try await Task.detached(priority: .userInitiated) {
                    try AudioClip.load(from: url) { fraction in
                        Task { @MainActor in self?.updateWorking("녹음 파일을 읽는 중…", fraction) }
                    }
                }.value
                try Task.checkCancellation()
                self?.updateWorking("노래 구간을 찾는 중…", 0)
                let windows = try await Task.detached(priority: .userInitiated) {
                    try ContentDetector.classify(clip) { fraction in
                        Task { @MainActor in self?.updateWorking("노래 구간을 찾는 중…", fraction) }
                    } isCancelled: {
                        Task.isCancelled
                    }
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                source = clip
                classifiedWindows = windows
                recordingDuration = clip.duration
                detectedSegments = ContentDetector.segments(from: windows, duration: clip.duration)
                sourceSegments = detectedSegments
                segmentsWereEdited = false
                await process(clip)
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                phase = .empty
                recordingURL = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateWorking(_ message: String, _ fraction: Double?) {
        guard case .working(let current, let currentFraction) = phase else { return }
        // Updates can arrive out of order; within one step, the bar only moves forward.
        if current == message, let currentFraction, let fraction, fraction < currentFraction { return }
        phase = .working(message: message, fraction: fraction)
    }

    // MARK: - Editing the sound

    private func scheduleProcessing() {
        guard let source else { return }
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            // Waits a moment so dragging a slider doesn't start over on every step.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.process(source)
        }
    }

    private func process(_ clip: AudioClip) async {
        phase = .working(message: "소리를 다듬는 중…", fraction: nil)
        let options = audioOptions
        let fps = settings.framesPerSecond
        let previewURL = FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).wav")
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                let processed = AudioProcessor.process(clip, options: options)
                try Task.checkCancellation()
                try processed.clip.write(
                    to: previewURL,
                    settings: AudioClip.wavSettings(sampleRate: processed.clip.sampleRate, channels: processed.clip.channels.count)
                )
                return (processed, Self.makePeaks(processed.clip), Performance.voiceLevels(processed.clip, framesPerSecond: fps))
            }.value
            try Task.checkCancellation()
            let oldPreview = processed == nil ? nil : player.time
            processed = result.0
            peaks = result.1
            voiceLevels = (result.2, fps)
            await buildPerformance()
            player.load(previewURL)
            if let oldPreview { player.seek(to: oldPreview) }
            phase = .ready
        } catch {
            try? FileManager.default.removeItem(at: previewURL)
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
                phase = processed == nil ? .empty : .ready
            }
        }
    }

    nonisolated private static func makePeaks(_ clip: AudioClip) -> [Float] {
        guard clip.frameCount > 0 else { return [] }
        let step = max(1, Int(clip.sampleRate / peaksPerSecond))
        let count = (clip.frameCount + step - 1) / step
        var peaks = [Float](repeating: 0, count: count)
        // Straight from each channel: a mono copy of a whole show would be hundreds of megabytes.
        for channel in clip.channels {
            channel.withUnsafeBufferPointer { samples in
                for index in 0..<count {
                    let start = index * step
                    guard start < samples.count else { break }
                    var peak: Float = 0
                    vDSP_maxmgv(samples.baseAddress! + start, 1, &peak, vDSP_Length(min(step, samples.count - start)))
                    peaks[index] = max(peaks[index], min(peak, 1))
                }
            }
        }
        return peaks
    }

    /// Trims the recording so it starts at the preview's current position.
    func startHere() {
        guard let processed else { return }
        audioOptions.trimStart = processed.timeMap.sourceTime(at: player.time)
        player.seek(to: 0)
    }

    /// Trims the recording so it ends at the preview's current position.
    func endHere() {
        guard let processed else { return }
        audioOptions.trimEnd = processed.timeMap.sourceTime(at: player.time)
    }

    func clearTrim() {
        audioOptions.trimStart = 0
        audioOptions.trimEnd = nil
    }

    // MARK: - Songs and talk

    /// Makes everything from `start` to `end` of the edited audio a song, or talk. For when the automatic guess got it
    /// wrong.
    func setSegment(from start: Double, to end: Double, isMusic: Bool) {
        guard let processed, end > start else { return }
        let sourceStart = processed.timeMap.sourceTime(at: start)
        let sourceEnd = processed.timeMap.sourceTime(at: end)
        guard sourceEnd > sourceStart else { return }

        var edited = [ContentSegment]()
        for segment in sourceSegments {
            if segment.end <= sourceStart || segment.start >= sourceEnd {
                edited.append(segment)
                continue
            }
            if segment.start < sourceStart {
                edited.append(ContentSegment(start: segment.start, end: sourceStart, isMusic: segment.isMusic))
            }
            if segment.end > sourceEnd {
                edited.append(ContentSegment(start: sourceEnd, end: segment.end, isMusic: segment.isMusic))
            }
        }
        edited.append(ContentSegment(start: sourceStart, end: sourceEnd, isMusic: isMusic))
        commitSegments(edited)
    }

    /// Moves the border between two stretches that's at `from` in the edited audio to `to`.
    func moveSegmentBorder(from: Double, to: Double) {
        guard let processed, sourceSegments.count > 1 else { return }
        let old = processed.timeMap.sourceTime(at: from)
        let new = processed.timeMap.sourceTime(at: to)
        // The border nearest where the drag started.
        guard let index = (1..<sourceSegments.count).min(by: {
            abs(sourceSegments[$0].start - old) < abs(sourceSegments[$1].start - old)
        }) else { return }
        let lowest = sourceSegments[index - 1].start + 0.5
        let highest = sourceSegments[index].end - 0.5
        guard highest > lowest else { return }
        let time = min(max(new, lowest), highest)
        var edited = sourceSegments
        edited[index - 1].end = time
        edited[index].start = time
        commitSegments(edited)
    }

    func restoreDetectedSegments() {
        sourceSegments = detectedSegments
        segmentsWereEdited = false
        rebuildPerformance()
    }

    private func commitSegments(_ segments: [ContentSegment]) {
        var merged = [ContentSegment]()
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.end > segment.start {
            if let last = merged.last, last.isMusic == segment.isMusic {
                merged[merged.count - 1].end = max(last.end, segment.end)
            } else {
                merged.append(segment)
            }
        }
        sourceSegments = merged
        segmentsWereEdited = true
        rebuildPerformance()
    }

    // MARK: - Performance

    private func rebuildPerformance() {
        Task { await buildPerformance() }
    }

    private func buildPerformance() async {
        let fps = settings.framesPerSecond
        guard let processed else {
            performance = Performance.idle(framesPerSecond: fps)
            return
        }
        let segments = sourceSegments
        let windows = classifiedWindows
        let sensitivity = settings.mouthSensitivity
        let eyes = settings.listeningEyes
        let cached = voiceLevels?.framesPerSecond == fps ? voiceLevels?.levels : nil
        let (levels, built) = await Task.detached(priority: .userInitiated) {
            let levels = cached ?? Performance.voiceLevels(processed.clip, framesPerSecond: fps)
            let built = Performance.make(
                audio: processed,
                voiceLevels: levels,
                sourceSegments: segments,
                speechWindows: windows,
                framesPerSecond: fps,
                mouthSensitivity: sensitivity,
                listeningEyes: eyes
            )
            return (levels, built)
        }.value
        // A newer recording or edit may have arrived while this was being worked out.
        guard self.processed.map({ $0.clip.frameCount == processed.clip.frameCount }) ?? false else { return }
        voiceLevels = (levels, fps)
        performance = built
    }

    // MARK: - Preview picture

    static let previewSize = CGSize(width: 960, height: 540)

    /// The picture at a moment in the preview. Without a recording, the character idles on a loop.
    func previewImage(at time: Double) -> CGImage? {
        if previewRenderer == nil || previewRendererRevision != layers.revision {
            previewRenderer = FrameRenderer(images: layers.images, size: Self.previewSize)
            previewRendererRevision = layers.revision
        }
        var frame = Int(time * Double(performance.framesPerSecond))
        if !hasRecording, performance.frameCount > 0 {
            frame %= performance.frameCount
        }
        let pose = performance.pose(at: frame, swayAmount: settings.swayAmount)
        return previewRenderer?.makeImage(pose: pose, settings: settings)
    }

    // MARK: - Exporting

    var suggestedName: String {
        recordingURL?.deletingPathExtension().lastPathComponent ?? "ABS 라디오"
    }

    func exportVideo() {
        guard let processed, !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = suggestedName + ".mp4"
        panel.message = "유튜브에 올릴 영상을 저장할 곳을 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        player.pause()
        let cancel = CancelFlag()
        exportCancel = cancel
        export = ExportState()
        let performance = performance
        let images = layers.images
        let settings = settings
        Task { [weak self] in
            do {
                try await VideoExporter.export(
                    audio: processed.clip,
                    performance: performance,
                    images: images,
                    settings: settings,
                    to: url,
                    progress: { progress in
                        Task { @MainActor in
                            guard let self, self.export?.finishedURL == nil else { return }
                            self.export?.fraction = progress.fraction
                            self.export?.message = progress.message
                        }
                    },
                    isCancelled: { cancel.isSet }
                )
                self?.export?.fraction = 1
                self?.export?.finishedURL = url
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                self?.export = nil
            } catch {
                try? FileManager.default.removeItem(at: url)
                self?.export?.errorMessage = error.localizedDescription
            }
        }
    }

    func exportAudio() {
        guard let processed, !isBusy else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio, .wav]
        panel.nameFieldStringValue = suggestedName + " (편집).m4a"
        panel.message = "다듬은 소리를 저장할 곳을 고르세요. 이름 끝을 .wav로 바꾸면 WAV로 저장돼요."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let clip = processed.clip
        let isWAV = url.pathExtension.lowercased() == "wav"
        let cancel = CancelFlag()
        exportCancel = cancel
        export = ExportState(message: "소리를 저장하는 중…")
        Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    let settings = isWAV
                        ? AudioClip.wavSettings(sampleRate: clip.sampleRate, channels: clip.channels.count)
                        : AudioClip.aacSettings(sampleRate: clip.sampleRate, channels: clip.channels.count)
                    try clip.write(to: url, settings: settings) { fraction in
                        Task { @MainActor in self?.export?.fraction = fraction }
                    }
                }.value
                self?.export?.fraction = 1
                self?.export?.finishedURL = url
            } catch {
                self?.export?.errorMessage = error.localizedDescription
            }
        }
    }

    func cancelExport() {
        exportCancel.set()
    }
}

/// A yes-or-no that one task sets and another checks.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
