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
