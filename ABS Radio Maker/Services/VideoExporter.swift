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
/// The picture is drawn on several cores and the sound encoded alongside it, straight into the finished file.
enum VideoExporter {
    static let size = CGSize(width: 1920, height: 1080)

    struct Progress: Sendable {
        var fraction: Double
        var message: String
    }

    /// Runs away from the main thread, so the window keeps answering while a long show is written. The picture and the
    /// sound go into the finished file together, as they're made, so nothing is written twice.
    @concurrent static func export(
        audio: AudioClip,
        performance: Performance,
        images: [LayerSlot: CGImage],
        settings: StudioSettings,
        to destination: URL,
        progress: @escaping @Sendable (Progress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        progress(Progress(fraction: 0, message: "영상을 만드는 중…"))
        // The save panel has already asked whether to replace a file that's there.
        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
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
        let sound = try SoundFeeder(audio: audio)
        guard writer.canAdd(input), writer.canAdd(sound.input) else { throw VideoExportError.cannotStartWriter("input") }
        writer.add(input)
        writer.add(sound.input)
        guard writer.startWriting() else {
            throw VideoExportError.cannotStartWriter(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let renderer = FrameRenderer(images: images, size: size)
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
        do {
            while let current = pending {
                let batch = try await current.value
                let first = frame
                frame += batch.buffers.count
                pending = frame < frameCount ? drawing.start(first: frame, count: min(batchSize, frameCount - frame)) : nil

                for (index, pixelBuffer) in batch.buffers.enumerated() {
                    if isCancelled() { throw CancellationError() }
                    let time = Double(first + index) / Double(fps)
                    // The file holds picture and sound side by side, so the sound is kept a little ahead of the picture:
                    // the writer waits for whichever falls behind.
                    while !input.isReadyForMoreMediaData {
                        if writer.status == .failed {
                            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                        }
                        if try !sound.feed(until: time + 2) {
                            try await Task.sleep(for: .milliseconds(2))
                        }
                    }
                    if !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(first + index), timescale: fps)) {
                        throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "append")
                    }
                    _ = try sound.feed(until: time + 1)
                }

                let done = Double(frame) / Double(frameCount)
                let elapsed = Date().timeIntervalSince(started)
                // A guess at the time left is only steady after a few seconds.
                let remaining = elapsed > 5 ? elapsed / done * (1 - done) : nil
                let message: String
                if let remaining, remaining > 0 {
                    message = "영상을 만드는 중… 약 \(Self.describe(remaining)) 남음"
                } else {
                    message = "영상을 만드는 중…"
                }
                progress(Progress(fraction: done * 0.98, message: message))
            }
            input.markAsFinished()
            // Whatever sound is left after the last frame.
            while !sound.isFinished {
                if writer.status == .failed {
                    throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
                }
                if try !sound.feed(until: .infinity) {
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            sound.input.markAsFinished()
        } catch {
            pending?.cancel()
            writer.cancelWriting()
            throw error
        }

        progress(Progress(fraction: 0.99, message: "마무리하는 중…"))
        await writer.finishWriting()
        if writer.status != .completed {
            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "finish")
        }
        progress(Progress(fraction: 1, message: "완료"))
    }

    /// Hands the recording to the writer's AAC encoder a few thousand samples at a time, as 32-bit float with the
    /// channels side by side.
    private final class SoundFeeder {
        let input: AVAssetWriterInput
        private let audio: AudioClip
        private let format: CMAudioFormatDescription
        private var position = 0
        private static let chunk = 4096

        var isFinished: Bool { position >= audio.frameCount }

        init(audio: AudioClip) throws {
            self.audio = audio
            let channels = audio.channels.count
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioClip.aacSettings(sampleRate: audio.sampleRate, channels: channels))
            input.expectsMediaDataInRealTime = false
            var description = AudioStreamBasicDescription(
                mSampleRate: audio.sampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(4 * channels),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(4 * channels),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var format: CMAudioFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
            )
            guard status == noErr, let format else { throw VideoExportError.cannotStartWriter("sound format \(status)") }
            self.format = format
        }

        /// Appends sound up to a time in seconds while the writer takes it. Whether anything was appended.
        func feed(until seconds: Double) throws -> Bool {
            let limit = seconds.isInfinite ? audio.frameCount : min(audio.frameCount, Int(seconds * audio.sampleRate))
            var appended = false
            while position < limit, input.isReadyForMoreMediaData {
                let count = min(Self.chunk, limit - position)
                try input.append(sampleBuffer(from: position, count: count))
                position += count
                appended = true
            }
            return appended
        }

        private func sampleBuffer(from start: Int, count: Int) throws -> CMSampleBuffer {
            let channels = audio.channels.count
            let byteCount = count * channels * 4
            var block: CMBlockBuffer?
            var status = CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            )
            guard status == noErr, let block else { throw VideoExportError.writerFailed("sound block \(status)") }
            var pointer: UnsafeMutablePointer<CChar>?
            status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
            guard status == noErr, let pointer else { throw VideoExportError.writerFailed("sound data \(status)") }
            pointer.withMemoryRebound(to: Float.self, capacity: count * channels) { samples in
                for (channel, source) in audio.channels.enumerated() {
                    source.withUnsafeBufferPointer { source in
                        for frame in 0..<count {
                            samples[frame * channels + channel] = source[start + frame]
                        }
                    }
                }
            }
            var buffer: CMSampleBuffer?
            status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audio.sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer
            )
            guard status == noErr, let buffer else { throw VideoExportError.writerFailed("sound buffer \(status)") }
            return buffer
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
            Task.detached(priority: .userInitiated) {
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

    static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)초" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분" }
        return "\(minutes / 60)시간 \(minutes % 60)분"
    }
}
