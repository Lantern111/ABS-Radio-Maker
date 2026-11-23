import Accelerate
import AppKit
import AVFoundation
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
    let plugins = PluginChain()
    /// What the timeline shows and what's selected in it, shared by the timeline, its buttons, and the keyboard.
    let timeline = TimelineViewport()
    /// The window's undo manager, so cutting and changing stretches can be undone with ⌘Z.
    @ObservationIgnored weak var undoManager: UndoManager?

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

    /// The channel EQ, first in line before the plug-ins. The preview hears changes at once.
    var equalizer = EQSettings.load() {
        didSet {
            guard equalizer != oldValue else { return }
            equalizer.save()
            ChannelEQ.apply(equalizer, to: liveEQ)
            if equalizer.scope != oldValue.scope { updateInserts() }
            if equalizer.isActive || oldValue.isActive { scheduleProcessing(quietly: true) }
        }
    }

    /// How long an effect kept to talk or to songs takes to fade in or out where the stretch changes, in seconds.
    var insertTransition = Studio.loadTransition() {
        didSet {
            guard insertTransition != oldValue else { return }
            UserDefaults.standard.set(insertTransition, forKey: Self.transitionKey)
            updateEnvelope()
            if usesScopes { scheduleProcessing(quietly: true) }
        }
    }
    static let transitionChoices: [Double] = [0.2, 0.5, 1, 2, 3]

    var spectrumSettings = SpectrumSettings.load() {
        didSet {
            guard spectrumSettings != oldValue else { return }
            spectrumSettings.save()
            applySpectrumSettings()
        }
    }

    /// The EQ the preview plays through. The export gets a copy with the same settings.
    @ObservationIgnored let liveEQ = AVAudioUnitEQ(numberOfBands: EQSettings.standardBands.count)

    private(set) var phase = Phase.empty
    private(set) var recordingURL: URL?
    private(set) var recordingDuration: Double = 0
    private(set) var processed: ProcessedAudio?
    private(set) var performance: Performance
    /// Song and talk stretches in the original recording's time. Neighbors can be the same kind once a stretch has been
    /// cut in two.
    private(set) var sourceSegments: [ContentSegment] = [] {
        didSet { updateTimelineSegments() }
    }
    /// The same stretches in the edited audio's time, for the timeline.
    private(set) var timelineSegments: [ContentSegment] = []
    private(set) var segmentsWereEdited = false
    /// Peak levels for drawing the timeline, from 0 to 1, `peaksPerSecond` of them for each second of edited audio.
    private(set) var peaks: [Float] = []
    nonisolated static let peaksPerSecond = 100.0
    var export: ExportState?
    var errorMessage: String?
    var showsShortcuts = false
    /// How far the plug-ins have got through the recording, while they're applied again after a change. The preview
    /// already plays them live; this brings the export and the mouth up to date. Nil when there's nothing to catch up.
    private(set) var applyingPlugins: Double?

    private static let transitionKey = "insertTransition"

    private static func loadTransition() -> Double {
        let saved = UserDefaults.standard.double(forKey: transitionKey)
        return saved > 0 ? saved : 1
    }

    @ObservationIgnored private var source: SourceAudio?
    @ObservationIgnored private var detectedSegments: [ContentSegment] = []
    @ObservationIgnored private var classifiedWindows: [ClassifiedWindow] = []
    /// When the announcer is talking, from the trained detector. Nil when the app has no model.
    @ObservationIgnored private var talkMoments: [TalkDetector.Moment]?
    /// Voice levels for each frame of the edited audio, and the frame rate they were measured at.
    @ObservationIgnored private var voiceLevels: (levels: [Float], framesPerSecond: Int)?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var exportCancel = CancelFlag()
    @ObservationIgnored private var cachedSceneRenderer: (renderer: FrameRenderer, revision: Int)?
    /// The preview's audio file: the cleaned-up recording, before plug-ins, and the options that made it.
    @ObservationIgnored private var preview: (url: URL, options: AudioEditOptions)?

    static let audioTypes: [UTType] = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]

    init() {
        let settings = StudioSettings.load()
        performance = Performance.idle(framesPerSecond: settings.framesPerSecond)
        ChannelEQ.apply(equalizer, to: liveEQ)
        applySpectrumSettings()
        plugins.onChange = { [weak self] in self?.pluginsChanged() }
        updateInserts()
        plugins.restore()
    }

    /// The preview hears the change at once; the export and the mouth follow in the background.
    private func pluginsChanged() {
        updateInserts()
        scheduleProcessing(quietly: true)
    }

    /// The EQ, then the plug-ins that are on, in the preview.
    private func updateInserts() {
        let plugged = plugins.loaded.filter(\.isOn).map { PlayerInsert(unit: $0.unit, scope: $0.scope) }
        player.setInserts([PlayerInsert(unit: liveEQ, scope: equalizer.scope)] + plugged)
    }

    private func updateEnvelope() {
        player.setEnvelope(ScopeEnvelope(segments: timelineSegments, transition: insertTransition))
    }

    private func applySpectrumSettings() {
        player.spectrum.fftSize = spectrumSettings.fftSize
        player.spectrum.smoothing = Float(spectrumSettings.smoothing)
    }

    /// Whether any effect is kept to talk or to songs, so changing where they are changes the sound.
    var usesScopes: Bool {
        (equalizer.isActive && equalizer.scope != .everything)
            || plugins.loaded.contains { $0.isOn && $0.scope != .everything }
    }

    /// Changes one EQ band, kept within what the EQ can do.
    func setBand(_ band: EQBand) {
        guard equalizer.bands.indices.contains(band.id) else { return }
        equalizer.bands[band.id] = band.clamped()
    }

    func resetEqualizer() {
        equalizer.bands = EQSettings.standardBands
    }

    var hasRecording: Bool { processed != nil }

    var isBusy: Bool {
        if case .working = phase { return true }
        if applyingPlugins != nil { return true }
        return isExporting
    }

    private var isExporting: Bool {
        export != nil && export?.finishedURL == nil && export?.errorMessage == nil
    }

    /// Stretches can still be changed while effects catch up in the background; the catching up starts over.
    var canEditSegments: Bool {
        guard hasRecording, case .ready = phase else { return false }
        return !isExporting
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
        removePreview()
        // Cleared first, so resetting the trim below doesn't start processing the previous recording.
        source = nil
        processed = nil
        peaks = []
        voiceLevels = nil
        sourceSegments = []
        undoManager?.removeAllActions(withTarget: self)
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
                let cancel = CancelFlag()
                // Reading, finding songs, and moving the original to a file happen together, so the decoded
                // recording is let go of as soon as the file is written.
                let (windows, moments, segments, source) = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        let reading = ProgressGate(), finding = ProgressGate(), detecting = ProgressGate()
                        let clip = try AudioClip.load(from: url) { fraction in
                            guard reading.passes(fraction) else { return }
                            Task { @MainActor in self?.updateWorking("녹음 파일을 읽는 중…", fraction) }
                        }
                        if cancel.isSet { throw CancellationError() }
                        let windows = try ContentDetector.classify(clip) { fraction in
                            guard finding.passes(fraction) else { return }
                            Task { @MainActor in self?.updateWorking("노래 구간을 찾는 중…", fraction) }
                        } isCancelled: {
                            cancel.isSet
                        }
                        // The trained detector is better at telling talking over background music from music in a
                        // pause. Without it, the built-in classifier decides.
                        var moments: [TalkDetector.Moment]?
                        if let url = TalkDetector.bundledModel, let model = try? TalkDetector.loadModel(at: url) {
                            moments = try TalkDetector.detect(clip, model: model) { fraction in
                                guard detecting.passes(fraction) else { return }
                                Task { @MainActor in self?.updateWorking("말하는 순간을 찾는 중…", fraction) }
                            } isCancelled: {
                                cancel.isSet
                            }
                        }
                        // The trained detector also catches sung or rapped verses the built-in classifier took for talk.
                        var segments = ContentDetector.segments(from: windows, duration: clip.duration)
                        if let moments {
                            segments = ContentDetector.refine(segments, talk: moments, clip: clip)
                        }
                        return (windows, moments, segments, try SourceAudio(clip))
                    }.value
                } onCancel: {
                    cancel.set()
                }
                try Task.checkCancellation()
                guard let self else { return }
                self.source = source
                classifiedWindows = windows
                talkMoments = moments
                recordingDuration = source.duration
                detectedSegments = segments
                sourceSegments = detectedSegments
                segmentsWereEdited = false
                await process(source)
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

    private func scheduleProcessing(quietly: Bool = false) {
        guard let source else { return }
        let previous = processingTask
        previous?.cancel()
        processingTask = Task { [weak self] in
            // Waits a moment so dragging a slider or an EQ point doesn't start over on every step. Effects the
            // preview already plays live wait a little longer.
            try? await Task.sleep(for: .milliseconds(quietly ? 800 : 350))
            // The render being replaced lets go of the plug-in copies first, since they're shared.
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.process(source, quietly: quietly)
        }
    }

    /// Cleans up the recording, runs it through the plug-ins, and evens out its loudness. `quietly` keeps the preview
    /// showing while that happens, for plug-in changes the preview already plays live.
    private func process(_ source: SourceAudio, quietly: Bool = false) async {
        let quietly = quietly && processed != nil
        if quietly {
            applyingPlugins = 0
        } else {
            phase = .working(message: "소리를 다듬는 중…", fraction: nil)
        }
        let options = audioOptions
        let fps = settings.framesPerSecond
        // The preview only needs a new file when the clean-up changed, not for plug-ins, so playback carries on.
        let previewIsCurrent = preview?.options == options
        // When only the effects changed, the timing is the same, so the mouth worked out before still fits. It
        // follows the voice, which the effects barely move.
        let keepsMouth = quietly && previewIsCurrent && voiceLevels?.framesPerSecond == fps
        let previewURL = previewIsCurrent
            ? preview!.url
            : FileManager.default.temporaryDirectory.appending(path: "preview-\(UUID().uuidString).wav")
        let eq = equalizer
        let eqInsert = eq.isActive ? [RenderInsert(unit: ChannelEQ.makeUnit(eq), scope: eq.scope)] : []
        let inserts = eqInsert + (await plugins.renderCopies())
        let segments = sourceSegments
        let transition = insertTransition
        if !inserts.isEmpty, !quietly {
            phase = .working(message: "EQ와 플러그인을 적용하는 중…", fraction: 0)
        }
        let cancel = CancelFlag()
        do {
            let result = try await withTaskCancellationHandler {
              // Catching up in the background mustn't take time from the picture and the meters.
              try await Task.detached(priority: quietly ? .utility : .userInitiated) {
                let cleaned = AudioProcessor.clean(source, options: options)
                if cancel.isSet { throw CancellationError() }
                if !previewIsCurrent {
                    try cleaned.clip.write(
                        to: previewURL,
                        settings: AudioClip.floatSettings(sampleRate: cleaned.clip.sampleRate, channels: cleaned.clip.channels.count)
                    )
                }
                let plugged: CleanedAudio
                if inserts.isEmpty {
                    plugged = consume cleaned
                } else {
                    let envelope = ScopeEnvelope(
                        segments: Self.outputSegments(segments, map: cleaned.timeMap),
                        transition: transition
                    )
                    let gate = ProgressGate()
                    plugged = try PluginRenderer.render(consume cleaned, inserts: inserts, envelope: envelope) { fraction in
                        // Hundreds of blocks a second report progress; the bar only needs a few of them.
                        guard gate.passes(fraction) else { return }
                        Task { @MainActor in
                            if quietly {
                                self.applyingPlugins = fraction
                            } else {
                                self.updateWorking("EQ와 플러그인을 적용하는 중…", fraction)
                            }
                        }
                    } isCancelled: {
                        cancel.isSet
                    }
                }
                let processed = AudioProcessor.finish(consume plugged, options: options)
                let levels = keepsMouth ? nil : Performance.voiceLevels(processed.clip, framesPerSecond: fps)
                return (processed, Self.makePeaks(processed.clip), levels)
              }.value
            } onCancel: {
                cancel.set()
            }
            try Task.checkCancellation()
            let oldPreview = processed == nil ? nil : player.time
            processed = result.0
            peaks = result.1
            updateTimelineSegments()
            if let levels = result.2 {
                voiceLevels = (levels, fps)
                await buildPerformance()
            }
            if !previewIsCurrent {
                removePreview()
                preview = (previewURL, options)
                player.load(previewURL)
                if let oldPreview { player.seek(to: oldPreview) }
            }
            player.setGain(result.0.gain)
            updateInserts()
            applyingPlugins = nil
            phase = .ready
        } catch {
            if !previewIsCurrent { try? FileManager.default.removeItem(at: previewURL) }
            if !(error is CancellationError) {
                applyingPlugins = nil
                errorMessage = error.localizedDescription
                phase = processed == nil ? .empty : .ready
            }
        }
    }

    private func removePreview() {
        if let preview { try? FileManager.default.removeItem(at: preview.url) }
        preview = nil
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

    private func updateTimelineSegments() {
        guard let processed else {
            timelineSegments = []
            updateEnvelope()
            return
        }
        timelineSegments = Self.outputSegments(sourceSegments, map: processed.timeMap)
        updateEnvelope()
    }

    /// Stretches of the original recording, moved to the edited audio's time.
    nonisolated static func outputSegments(_ segments: [ContentSegment], map: TimeMap) -> [ContentSegment] {
        let duration = map.outputDuration
        return segments.compactMap { segment in
            let start = max(map.outputTime(atSource: segment.start), 0)
            let end = min(map.outputTime(atSource: segment.end), duration)
            return end - start > 0.01 ? ContentSegment(start: start, end: end, isMusic: segment.isMusic) : nil
        }
    }

    /// Where one stretch meets the next, in the edited audio's time.
    var segmentBorders: [Double] {
        timelineSegments.dropFirst().map(\.start)
    }

    /// Makes everything from `start` to `end` of the edited audio a song, or talk.
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
        commitSegments(edited, actionName: isMusic ? "노래로 바꾸기" : "말하기로 바꾸기")
    }

    /// Changes the stretch under a moment of the edited audio, keeping its borders.
    func setSegment(at time: Double, isMusic: Bool) {
        guard let segment = timelineSegment(at: time) else { return }
        setSegment(from: segment.start, to: segment.end, isMusic: isMusic)
    }

    func timelineSegment(at time: Double) -> ContentSegment? {
        timelineSegments.first { $0.start <= time && time < $0.end } ?? timelineSegments.last
    }

    /// Cuts the stretch under a moment of the edited audio in two, so each half can be made a song or talk.
    func splitSegment(at time: Double) {
        guard let processed else { return }
        let cut = processed.timeMap.sourceTime(at: time)
        guard let index = sourceSegments.firstIndex(where: { $0.start < cut && cut < $0.end }) else { return }
        let segment = sourceSegments[index]
        // Too close to an existing border to be worth a stretch of its own.
        guard cut - segment.start > 0.2, segment.end - cut > 0.2 else { return }
        var edited = sourceSegments
        edited[index].end = cut
        edited.insert(ContentSegment(start: cut, end: segment.end, isMusic: segment.isMusic), at: index + 1)
        commitSegments(edited, actionName: "구간 자르기")
    }

    /// Removes the border nearest a moment of the edited audio. The stretch before it takes over the one after.
    func removeBorder(near time: Double) {
        guard let processed, sourceSegments.count > 1 else { return }
        let target = processed.timeMap.sourceTime(at: time)
        guard let index = (1..<sourceSegments.count).min(by: {
            abs(sourceSegments[$0].start - target) < abs(sourceSegments[$1].start - target)
        }) else { return }
        var edited = sourceSegments
        edited[index - 1].end = edited[index].end
        edited.remove(at: index)
        commitSegments(edited, actionName: "경계 지우기")
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
        let lowest = sourceSegments[index - 1].start + 0.2
        let highest = sourceSegments[index].end - 0.2
        guard highest > lowest else { return }
        let time = min(max(new, lowest), highest)
        var edited = sourceSegments
        edited[index - 1].end = time
        edited[index].start = time
        commitSegments(edited, actionName: "경계 옮기기")
    }

    func restoreDetectedSegments() {
        commitSegments(detectedSegments, actionName: "자동으로 찾은 대로 되돌리기", edited: false)
    }

    /// Puts in new stretches, in a way ⌘Z can take back.
    private func commitSegments(_ segments: [ContentSegment], actionName: String, edited: Bool = true) {
        let cleaned = segments.sorted { $0.start < $1.start }.filter { $0.end > $0.start }
        replaceSegments(with: cleaned, edited: edited, actionName: actionName)
    }

    private func replaceSegments(with segments: [ContentSegment], edited: Bool, actionName: String) {
        let previous = sourceSegments
        let previousEdited = segmentsWereEdited
        undoManager?.registerUndo(withTarget: self) { studio in
            MainActor.assumeIsolated {
                studio.replaceSegments(with: previous, edited: previousEdited, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
        sourceSegments = segments
        segmentsWereEdited = edited
        timeline.selection = nil
        rebuildPerformance()
        // Effects kept to talk or songs follow the new stretches in the export too.
        if usesScopes { scheduleProcessing(quietly: true) }
    }

    // MARK: - Moving around

    var framesPerSecond: Double { Double(settings.framesPerSecond) }

    func step(frames: Int) {
        player.seek(to: player.time + Double(frames) / framesPerSecond)
        timeline.reveal(player.time)
    }

    /// Jumps to the next or previous border between stretches, or to the start or end.
    func jumpToBorder(forward: Bool) {
        let now = player.time
        let stops = [0] + segmentBorders + [player.duration]
        let target = forward ? stops.first { $0 > now + 0.01 } : stops.last { $0 < now - 0.01 }
        if let target {
            player.seek(to: target)
            timeline.reveal(target)
        }
    }

    func jump(to time: Double) {
        player.seek(to: time)
        timeline.reveal(player.time)
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
        let talking = talkMoments.map(TalkTimeline.init(moments:)) ?? TalkTimeline(windows: classifiedWindows)
        let sensitivity = settings.mouthSensitivity
        let eyes = settings.listeningEyes
        let cached = voiceLevels?.framesPerSecond == fps ? voiceLevels?.levels : nil
        let (levels, built) = await Task.detached(priority: .userInitiated) {
            let levels = cached ?? Performance.voiceLevels(processed.clip, framesPerSecond: fps)
            let built = Performance.make(
                audio: processed,
                voiceLevels: levels,
                sourceSegments: segments,
                talking: talking,
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

    // MARK: - Preview

    /// The layer pictures prepared at the video's size, for the preview. Remade when a picture changes.
    var sceneRenderer: FrameRenderer {
        if let cached = cachedSceneRenderer, cached.revision == layers.revision {
            return cached.renderer
        }
        let renderer = FrameRenderer(images: layers.images, size: VideoExporter.size)
        cachedSceneRenderer = (renderer, layers.revision)
        return renderer
    }

    /// What the character does at a moment. Without a recording, the character idles on a loop.
    func pose(at time: Double) -> Performance.Pose {
        var frame = Int(time * Double(performance.framesPerSecond))
        if !hasRecording, performance.frameCount > 0 {
            frame %= performance.frameCount
        }
        return performance.pose(at: frame, swayAmount: settings.swayAmount)
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
        let gate = ProgressGate()
        Task { [weak self] in
            do {
                try await VideoExporter.export(
                    audio: processed.clip,
                    performance: performance,
                    images: images,
                    settings: settings,
                    to: url,
                    progress: { progress in
                        guard gate.passes(progress.fraction) else { return }
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
                    let gate = ProgressGate()
                    try clip.write(to: url, settings: settings) { fraction in
                        guard gate.passes(fraction) else { return }
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

/// Lets through progress only when it has moved on a little, or at most ten times a second, so work reporting
/// every block doesn't flood the main thread with updates to a progress bar.
final class ProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private var lastTime = 0.0

    func passes(_ fraction: Double) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return lock.withLock {
            guard fraction >= 1 || (fraction - last >= 0.005 && now - lastTime >= 0.1) else { return false }
            last = fraction
            lastTime = now
            return true
        }
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
