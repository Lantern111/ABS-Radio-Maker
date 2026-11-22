import Accelerate
import AVFoundation

enum AudioClipError: LocalizedError {
    case noAudio
    case cannotCreateBuffer

    var errorDescription: String? {
        switch self {
        case .noAudio: "이 파일에서 소리를 찾지 못했어요."
        case .cannotCreateBuffer: "오디오를 처리할 메모리를 만들지 못했어요."
        }
    }
}

/// A whole recording decoded into memory, one array of samples per channel. Recordings with more than two channels
/// keep the first two.
struct AudioClip: Sendable {
    var channels: [[Float]]
    var sampleRate: Double

    var frameCount: Int { channels.first?.count ?? 0 }
    var duration: Double { Double(frameCount) / sampleRate }

    static func load(from url: URL, progress: (Double) -> Void = { _ in }) throws -> AudioClip {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = Int(file.length)
        guard total > 0, format.channelCount > 0 else { throw AudioClipError.noAudio }

        let channelCount = min(Int(format.channelCount), 2)
        var channels = (0..<channelCount).map { _ -> [Float] in
            var samples = [Float]()
            samples.reserveCapacity(total)
            return samples
        }

        let chunk: AVAudioFrameCount = 1 << 17
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioClipError.cannotCreateBuffer
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let count = Int(buffer.frameLength)
            if count == 0 { break }
            for channel in 0..<channelCount {
                channels[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: count))
            }
            progress(Double(file.framePosition) / Double(total))
        }
        return AudioClip(channels: channels, sampleRate: format.sampleRate)
    }

    /// The channels averaged into one.
    func mono() -> [Float] {
        guard channels.count > 1 else { return channels.first ?? [] }
        var mixed = vDSP.add(channels[0], channels[1])
        vDSP.multiply(0.5, mixed, result: &mixed)
        return mixed
    }

    /// Writes the clip to a file. The settings pick the format, for example AAC for a video's sound track.
    func write(to url: URL, settings: [String: Any], progress: (Double) -> Void = { _ in }) throws {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        ) else { throw AudioClipError.cannotCreateBuffer }

        let chunk = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw AudioClipError.cannotCreateBuffer
        }
        var position = 0
        while position < frameCount {
            let count = min(chunk, frameCount - position)
            for (index, channel) in channels.enumerated() {
                channel.withUnsafeBufferPointer { samples in
                    buffer.floatChannelData![index].update(from: samples.baseAddress! + position, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            position += count
            progress(Double(position) / Double(frameCount))
        }
    }

    static func aacSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels > 1 ? 256_000 : 160_000,
        ]
    }

    /// 32-bit float WAV, which keeps quiet audio exact before its loudness is evened out.
    static func floatSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func wavSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }
}

/// The original recording, decoded once and then kept in a temporary file rather than in memory. The file is mapped,
/// so the system reads in only the parts in use and can let them go again; a whole show would otherwise hold over half
/// a gigabyte for as long as it's open.
final class SourceAudio: @unchecked Sendable {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    private let url: URL
    private let data: Data

    var duration: Double { Double(frameCount) / sampleRate }

    /// Writes the clip's channels one after another as raw 32-bit samples.
    init(_ clip: AudioClip) throws {
        sampleRate = clip.sampleRate
        channelCount = clip.channels.count
        frameCount = clip.frameCount
        url = FileManager.default.temporaryDirectory.appending(path: "source-\(UUID().uuidString).raw")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        for channel in clip.channels {
            try channel.withUnsafeBytes { bytes in
                let chunk = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none)
                try handle.write(contentsOf: chunk)
            }
        }
        try handle.close()
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A copy of some of the frames, in memory, ready to edit.
    func clip(_ frames: Range<Int>) -> AudioClip {
        let frames = frames.clamped(to: 0..<frameCount)
        let channels = (0..<channelCount).map { channel in
            data.withUnsafeBytes { bytes in
                let samples = bytes.baseAddress!.assumingMemoryBound(to: Float.self) + channel * frameCount
                return Array(UnsafeBufferPointer(start: samples + frames.lowerBound, count: frames.count))
            }
        }
        return AudioClip(channels: channels, sampleRate: sampleRate)
    }
}
