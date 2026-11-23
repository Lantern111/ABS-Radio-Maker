import AVFoundation
import CoreVideo

enum VideoExportError: LocalizedError {
    case cannotStartWriter(String)
    case writerFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotStartWriter(let detail): "영상 파일을 만들기 시작하지 못했어요. (\(detail))"
        case .writerFailed(let detail): "영상을 쓰는 중에 문제가 생겼어요. (\(detail))"
        case .exportFailed(let detail): "영상과 소리를 합치지 못했어요. (\(detail))"
        }
    }
}

/// Makes the finished video: H.264 at 1920 × 1080 with the edited sound as AAC, in an MP4 file.
///
/// The picture and the sound are written to separate files first, then put together without re-encoding either.
enum VideoExporter {
    static let size = CGSize(width: 1920, height: 1080)

    struct Progress: Sendable {
        var fraction: Double
        var message: String
    }

    /// Runs away from the main thread, so the window keeps answering while a long show is written.
    @concurrent static func export(
        audio: AudioClip,
        performance: Performance,
        images: [LayerSlot: CGImage],
        settings: StudioSettings,
        to destination: URL,
        progress: @escaping @Sendable (Progress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        progress(Progress(fraction: 0, message: "소리를 준비하는 중…"))
        let soundURL = work.appending(path: "sound.m4a")
        try audio.write(to: soundURL, settings: AudioClip.aacSettings(sampleRate: audio.sampleRate, channels: audio.channels.count)) { fraction in
            progress(Progress(fraction: fraction * 0.05, message: "소리를 준비하는 중…"))
        }
        if isCancelled() { throw CancellationError() }

        let pictureURL = work.appending(path: "picture.mov")
        let renderer = FrameRenderer(images: images, size: size)
        try await writePicture(performance: performance, renderer: renderer, settings: settings, to: pictureURL, isCancelled: isCancelled) { fraction, remaining in
            let message: String
            if let remaining, remaining > 0 {
                message = "영상을 만드는 중… 약 \(Self.describe(remaining)) 남음"
            } else {
                message = "영상을 만드는 중…"
            }
            progress(Progress(fraction: 0.05 + fraction * 0.9, message: message))
        }

        progress(Progress(fraction: 0.95, message: "영상과 소리를 합치는 중…"))
        try await combine(picture: pictureURL, sound: soundURL, to: destination)
        progress(Progress(fraction: 1, message: "완료"))
    }

    private static func writePicture(
        performance: Performance,
        renderer: FrameRenderer,
        settings: StudioSettings,
        to url: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping (Double, TimeInterval?) -> Void
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let fps = Int32(performance.framesPerSecond)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { throw VideoExportError.cannotStartWriter("input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoExportError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let started = Date()
        let frameCount = performance.frameCount
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let backdrops = Backdrops(renderer: renderer, settings: settings, pose: performance.pose(at: 0, swayAmount: 0), colorSpace: colorSpace)
        // Frames don't depend on each other, so a batch is drawn on several cores at once and handed to the encoder in
        // order, while the next batch is already being drawn.
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount - 1, 8))
        let batchSize = workers * 2
        guard let pool = adaptor.pixelBufferPool else {
            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "pixel buffer pool")
        }
        let drawing = BatchDrawer(pool: pool, performance: performance, renderer: renderer, backdrops: backdrops,
                                  settings: settings, colorSpace: colorSpace)
        var pending: Task<BufferBox, Error>? = drawing.start(first: 0, count: min(batchSize, frameCount))
        var frame = 0
        while let current = pending {
            let batch = try await current.value
            let first = frame
            frame += batch.buffers.count
            pending = frame < frameCount ? drawing.start(first: frame, count: min(batchSize, frameCount - frame)) : nil

            for (index, pixelBuffer) in batch.buffers.enumerated() {
                if isCancelled() {
                    pending?.cancel()
                    writer.cancelWriting()
                    throw CancellationError()
                }
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
                if !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(first + index), timescale: fps)) {
                    throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "append")
                }
            }

            let done = Double(frame) / Double(frameCount)
            let elapsed = Date().timeIntervalSince(started)
            // A guess at the time left is only steady after a few seconds.
            let remaining = elapsed > 5 ? elapsed / done * (1 - done) : nil
            progress(done, remaining)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "finish")
        }
    }

    /// Pixel buffers handed to the threads drawing a batch. Each thread only touches its own.
    private struct BufferBox: @unchecked Sendable {
        let buffers: [CVPixelBuffer]

        init(_ buffers: [CVPixelBuffer]) {
            self.buffers = buffers
        }
    }

    /// Draws batches of frames into new pixel buffers, on several cores, away from the encoding.
    private struct BatchDrawer: @unchecked Sendable {
        let pool: CVPixelBufferPool
        let performance: Performance
        let renderer: FrameRenderer
        let backdrops: Backdrops
        let settings: StudioSettings
        let colorSpace: CGColorSpace

        func start(first: Int, count: Int) -> Task<BufferBox, Error> {
            Task.detached(priority: .utility) {
                var buffers: [CVPixelBuffer] = []
                for _ in 0..<count {
                    var pixelBuffer: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
                        throw VideoExportError.writerFailed("pixel buffer")
                    }
                    buffers.append(pixelBuffer)
                }
                let batch = BufferBox(buffers)
                DispatchQueue.concurrentPerform(iterations: count) { index in
                    VideoExporter.drawFrame(first + index, into: batch.buffers[index], performance: performance, renderer: renderer,
                                            backdrops: backdrops, settings: settings, colorSpace: colorSpace)
                }
                return batch
            }
        }
    }

    /// Draws one frame into a pixel buffer. Safe to run for different frames at once.
    private static func drawFrame(
        _ frame: Int,
        into pixelBuffer: CVPixelBuffer,
        performance: Performance,
        renderer: FrameRenderer,
        backdrops: Backdrops,
        settings: StudioSettings,
        colorSpace: CGColorSpace
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer), let context = CGContext(
            data: base,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        let pose = performance.pose(at: frame, swayAmount: settings.swayAmount)
        if renderer.isFading(pose) {
            // The song background part way in: drawn in full, which only a second or so of each fade needs.
            renderer.draw(in: context, pose: pose, settings: settings)
            return
        }
        // The parts that don't move come from the backdrop. Only around the character is anything drawn: the backdrop
        // without the desk, then the character, then the desk in front.
        let music = renderer.musicBackground != nil && pose.listening >= 0.999
        backdrops.copy(music: music, desk: true, into: base, bytesPerRow: bytesPerRow, area: nil)
        if let box = renderer.characterBox(pose: pose, settings: settings) {
            backdrops.copy(music: music, desk: false, into: base, bytesPerRow: bytesPerRow, area: box)
            renderer.draw(in: context, pose: pose, settings: settings, parts: [.character, .desk], listening: pose.listening, clip: box)
        }
    }

    /// Everything that doesn't move, drawn once: with and without the song background, each with and without the desk.
    /// Only read once made, so the threads drawing frames share it.
    private final class Backdrops: @unchecked Sendable {
        private let width: Int
        private let height: Int
        private let bytesPerRow: Int
        private var pictures: [Int: [UInt8]] = [:]

        init(renderer: FrameRenderer, settings: StudioSettings, pose: Performance.Pose, colorSpace: CGColorSpace) {
            width = Int(renderer.size.width)
            height = Int(renderer.size.height)
            bytesPerRow = width * 4
            let musicChoices = renderer.musicBackground == nil ? [false] : [false, true]
            for music in musicChoices {
                for desk in [false, true] {
                    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
                    pixels.withUnsafeMutableBytes { bytes in
                        guard let context = CGContext(
                            data: bytes.baseAddress,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                        ) else { return }
                        renderer.draw(
                            in: context,
                            pose: pose,
                            settings: settings,
                            parts: desk ? [.backdrop, .desk] : [.backdrop],
                            listening: music ? 1 : 0
                        )
                    }
                    pictures[Self.key(music: music, desk: desk)] = pixels
                }
            }
        }

        private static func key(music: Bool, desk: Bool) -> Int { (music ? 2 : 0) + (desk ? 1 : 0) }

        /// Copies a backdrop into a frame, all of it or just an area given in top-left-origin pixels. Rows in memory
        /// run from the top, so the area's rows are the rows to copy.
        func copy(music: Bool, desk: Bool, into destination: UnsafeMutableRawPointer, bytesPerRow destinationRow: Int, area: CGRect?) {
            guard let pixels = pictures[Self.key(music: music, desk: desk)] else { return }
            let left = area.map { max(Int($0.minX), 0) } ?? 0
            let right = area.map { min(Int($0.maxX), width) } ?? width
            let top = area.map { max(Int($0.minY), 0) } ?? 0
            let bottom = area.map { min(Int($0.maxY), height) } ?? height
            guard right > left, bottom > top else { return }
            let length = (right - left) * 4
            pixels.withUnsafeBytes { source in
                for row in top..<bottom {
                    (destination + row * destinationRow + left * 4)
                        .copyMemory(from: source.baseAddress! + row * bytesPerRow + left * 4, byteCount: length)
                }
            }
        }
    }

    private static func combine(picture: URL, sound: URL, to destination: URL) async throws {
        let pictureAsset = AVURLAsset(url: picture)
        let soundAsset = AVURLAsset(url: sound)
        guard let videoTrack = try await pictureAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await soundAsset.loadTracks(withMediaType: .audio).first
        else { throw VideoExportError.exportFailed("tracks") }
        let videoRange = try await videoTrack.load(.timeRange)
        let audioRange = try await audioTrack.load(.timeRange)
        let duration = CMTimeMinimum(videoRange.duration, audioRange.duration)

        let composition = AVMutableComposition()
        guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw VideoExportError.exportFailed("composition") }
        try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoExportError.exportFailed("session")
        }
        try? FileManager.default.removeItem(at: destination)
        if #available(macOS 15, *) {
            try await session.export(to: destination, as: .mp4)
        } else {
            session.outputURL = destination
            session.outputFileType = .mp4
            await session.export()
            if session.status != .completed {
                throw VideoExportError.exportFailed(session.error?.localizedDescription ?? "unknown")
            }
        }
    }

    static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)초" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분" }
        return "\(minutes / 60)시간 \(minutes % 60)분"
    }
}
