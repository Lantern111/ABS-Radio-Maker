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

    static func export(
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
        for frame in 0..<frameCount {
            if isCancelled() {
                writer.cancelWriting()
                throw CancellationError()
            }
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                }
                try await Task.sleep(for: .milliseconds(2))
            }

            var pixelBuffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer
            else { throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "pixel buffer") }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                renderer.draw(in: context, pose: performance.pose(at: frame, swayAmount: settings.swayAmount), settings: settings)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            if !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) {
                throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "append")
            }

            if frame % 30 == 0 || frame == frameCount - 1 {
                let done = Double(frame + 1) / Double(frameCount)
                let elapsed = Date().timeIntervalSince(started)
                // A guess at the time left is only steady after a few seconds.
                let remaining = elapsed > 5 ? elapsed / done * (1 - done) : nil
                progress(done, remaining)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "finish")
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
