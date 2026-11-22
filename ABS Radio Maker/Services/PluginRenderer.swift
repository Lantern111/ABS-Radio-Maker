import AVFoundation

/// Hands a plug-in across threads. Audio Units are made to be passed to whoever plays them.
struct UnitBox: @unchecked Sendable {
    let unit: AVAudioUnit
}

/// Runs the whole cleaned-up recording through copies of the plug-ins, as fast as they'll go, for the export and for
/// working out the mouth. The preview hears the same plug-ins live.
enum PluginRenderer {
    enum RenderError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let detail): "플러그인을 적용하지 못했어요. (\(detail))"
            }
        }
    }

    /// Hands the recording to the engine a block at a time, from the engine's own thread.
    private final class Feeder: @unchecked Sendable {
        let channels: [[Float]]
        let frameCount: Int
        var position = 0

        init(_ channels: [[Float]]) {
            self.channels = channels
            frameCount = channels.first?.count ?? 0
        }
    }

    static func render(
        _ cleaned: consuming CleanedAudio,
        through units: [UnitBox],
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> CleanedAudio {
        let timeMap = cleaned.timeMap
        let rate = cleaned.clip.sampleRate
        let feeder = Feeder((consume cleaned).clip.channels)
        let frameCount = feeder.frameCount
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw RenderError.failed("format")
        }

        // Offline mode comes first, so the engine never opens the Mac's audio output for this.
        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)

        let source = AVAudioSourceNode(format: format) { _, _, frames, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let count = Int(frames)
            let available = max(0, min(count, feeder.frameCount - feeder.position))
            for (index, buffer) in buffers.enumerated() {
                guard let output = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                // A mono recording feeds both sides.
                let channel = feeder.channels[min(index, feeder.channels.count - 1)]
                channel.withUnsafeBufferPointer { samples in
                    if available > 0 {
                        output.update(from: samples.baseAddress! + feeder.position, count: available)
                    }
                }
                if available < count {
                    (output + available).update(repeating: 0, count: count - available)
                }
            }
            feeder.position += count
            return noErr
        }

        let chain = units.map(\.unit)
        engine.attach(source)
        chain.forEach(engine.attach)
        let nodes: [AVAudioNode] = [source] + chain
        for (from, to) in zip(nodes, nodes.dropFirst()) {
            engine.connect(from, to: to, format: format)
        }
        engine.connect(nodes.last!, to: engine.mainMixerNode, format: format)
        try engine.start()
        defer { engine.stop() }

        // Some plug-ins hold the sound back, like a limiter looking ahead. Their delay is rendered past the end and
        // dropped from the start, so the sound stays in step with the picture.
        let delay = Int((chain.reduce(0) { $0 + $1.auAudioUnit.latency } * rate).rounded())
        let wanted = frameCount + delay
        var output = (0..<2).map { _ -> [Float] in
            var samples = [Float]()
            samples.reserveCapacity(wanted)
            return samples
        }
        guard let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw RenderError.failed("buffer")
        }
        while output[0].count < wanted {
            if isCancelled() { throw CancellationError() }
            let frames = AVAudioFrameCount(min(Int(chunk), wanted - output[0].count))
            let status = try engine.renderOffline(frames, to: scratch)
            guard status == .success, let data = scratch.floatChannelData else {
                throw RenderError.failed("render status \(status.rawValue)")
            }
            let got = Int(scratch.frameLength)
            guard got > 0 else { throw RenderError.failed("no output") }
            for channel in 0..<2 {
                let from = data[min(channel, Int(scratch.format.channelCount) - 1)]
                output[channel].append(contentsOf: UnsafeBufferPointer(start: from, count: got))
            }
            progress(Double(output[0].count) / Double(wanted))
        }
        if delay > 0 {
            for channel in 0..<2 { output[channel].removeFirst(delay) }
        }
        return CleanedAudio(clip: AudioClip(channels: output, sampleRate: rate), timeMap: timeMap)
    }
}
