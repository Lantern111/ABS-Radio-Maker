import AVFoundation

/// Hands a plug-in across threads. Audio Units are made to be passed to whoever plays them.
struct UnitBox: @unchecked Sendable {
    let unit: AVAudioUnit
}

/// An effect for the offline render, and the stretches it works on.
struct RenderInsert: @unchecked Sendable {
    let unit: AVAudioUnit
    let scope: InsertScope
}

/// Runs the whole cleaned-up recording through copies of the EQ and the plug-ins, as fast as they'll go, for the export
/// and for working out the mouth. The preview hears the same effects live.
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

    /// Mixes an effect's output with what went into it, for an effect that only works on some stretches.
    private struct Blend {
        let envelope: ScopeEnvelope
        let scope: InsertScope
    }

    /// Effects next to each other that work on the same stretches go through in one pass; each pass that only works
    /// on some stretches is faded in and out over the rest.
    static func render(
        _ cleaned: consuming CleanedAudio,
        inserts: [RenderInsert],
        envelope: ScopeEnvelope,
        progress: (Double) -> Void = { _ in },
        isCancelled: () -> Bool = { false }
    ) throws -> CleanedAudio {
        let groups = InsertScope.groups(inserts, scope: \.scope)
        var audio = consume cleaned
        for (index, group) in groups.enumerated() {
            let done = Double(index)
            let total = Double(groups.count)
            audio = try render(
                consume audio,
                through: group.items.map { UnitBox(unit: $0.unit) },
                blend: group.scope == .everything ? nil : Blend(envelope: envelope, scope: group.scope),
                progress: { progress((done + $0) / total) },
                isCancelled: isCancelled
            )
        }
        return audio
    }

    private static func render(
        _ cleaned: consuming CleanedAudio,
        through units: [UnitBox],
        blend: Blend?,
        progress: (Double) -> Void,
        isCancelled: () -> Bool
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
            samples.reserveCapacity(frameCount)
            return samples
        }
        guard let scratch = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw RenderError.failed("buffer")
        }
        var gains = [Float](repeating: 1, count: Int(chunk))
        var rendered = 0
        while output[0].count < frameCount {
            if isCancelled() { throw CancellationError() }
            let frames = AVAudioFrameCount(min(Int(chunk), wanted - rendered))
            let status = try engine.renderOffline(frames, to: scratch)
            guard status == .success, let data = scratch.floatChannelData else {
                throw RenderError.failed("render status \(status.rawValue)")
            }
            let got = Int(scratch.frameLength)
            guard got > 0 else { throw RenderError.failed("no output") }
            let skipped = min(max(delay - rendered, 0), got)
            rendered += got
            let kept = min(got - skipped, frameCount - output[0].count)
            if kept > 0 {
                let at = output[0].count
                for channel in 0..<2 {
                    let from = data[min(channel, Int(scratch.format.channelCount) - 1)] + skipped
                    output[channel].append(contentsOf: UnsafeBufferPointer(start: from, count: kept))
                }
                if let blend {
                    gains.withUnsafeMutableBufferPointer { gains in
                        blend.envelope.fill(gains.baseAddress!, for: blend.scope, from: at, count: kept, sampleRate: rate)
                    }
                    for channel in 0..<2 {
                        let dry = feeder.channels[min(channel, feeder.channels.count - 1)]
                        dry.withUnsafeBufferPointer { dry in
                            gains.withUnsafeBufferPointer { gains in
                                output[channel].withUnsafeMutableBufferPointer { wet in
                                    for index in 0..<kept {
                                        let original = dry[at + index]
                                        wet[at + index] = original + gains[index] * (wet[at + index] - original)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            progress(Double(rendered) / Double(wanted))
        }
        return CleanedAudio(clip: AudioClip(channels: output, sampleRate: rate), timeMap: timeMap)
    }
}
