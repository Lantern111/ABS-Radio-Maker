import AVFoundation

/// The channel EQ runs on Apple's own EQ, which uses the same filters `EQBand.response` draws.
enum ChannelEQ {
    static func makeUnit(_ settings: EQSettings) -> AVAudioUnitEQ {
        let unit = AVAudioUnitEQ(numberOfBands: settings.bands.count)
        apply(settings, to: unit)
        return unit
    }

    static func apply(_ settings: EQSettings, to unit: AVAudioUnitEQ) {
        unit.globalGain = 0
        unit.bypass = !settings.isActive
        for (band, parameters) in zip(settings.bands, unit.bands) {
            parameters.filterType = filterType(for: band.kind)
            parameters.frequency = Float(band.frequency)
            parameters.bandwidth = Float(min(max(band.bandwidth, 0.05), 5))
            parameters.gain = band.kind.hasGain ? Float(band.gain) : 0
            parameters.bypass = !band.isOn
        }
    }

    /// The resonant kinds take a width, so the cuts and shelves can have Q as in Logic Pro.
    private static func filterType(for kind: EQBand.Kind) -> AVAudioUnitEQFilterType {
        switch kind {
        case .lowCut: .resonantHighPass
        case .lowShelf: .resonantLowShelf
        case .bell: .parametric
        case .highShelf: .resonantHighShelf
        case .highCut: .resonantLowPass
        }
    }
}

/// How much of an effect to hear at each moment, for effects that only work on talk or only on songs. Across a border
/// between talk and a song the effect fades over `transition` seconds, centred on the border, so it never switches
/// on or off with a jump.
struct ScopeEnvelope: Sendable, Equatable {
    /// Song stretches in the edited audio's time, joined where they touch.
    private(set) var songs: [ClosedRange<Double>] = []
    private(set) var duration: Double = 0
    private(set) var transition: Double = 1

    init() {}

    init(segments: [ContentSegment], transition: Double) {
        self.transition = max(transition, 0)
        duration = segments.map(\.end).max() ?? 0
        for segment in segments.sorted(by: { $0.start < $1.start }) where segment.isMusic && segment.end > segment.start {
            if let last = songs.last, segment.start - last.upperBound < 0.001 {
                songs[songs.count - 1] = last.lowerBound...max(last.upperBound, segment.end)
            } else {
                songs.append(segment.start...segment.end)
            }
        }
    }

    func amount(for scope: InsertScope, at time: Double) -> Float {
        switch scope {
        case .everything: 1
        case .songs: Float(songAmount(at: time))
        case .talk: Float(1 - songAmount(at: time))
        }
    }

    /// How much of the stretch around a moment is song, from 0 to 1. Averaging over the transition turns each border
    /// into a straight fade, and a song shorter than the transition into a partial one.
    func songAmount(at time: Double) -> Double {
        guard !songs.isEmpty else { return 0 }
        let half = transition / 2
        var low = time - half
        var high = time + half
        // The recording's ends carry on as they are, so a show that opens with a song starts with the effect fully in.
        if duration > 0 {
            low = max(low, 0)
            high = min(high, duration)
        }
        guard half > 0.0005, high - low > 0.0005 else {
            return songs.contains { $0.lowerBound <= time && time < $0.upperBound } ? 1 : 0
        }
        // The first song that ends after the window starts.
        var first = 0
        var last = songs.count
        while first < last {
            let middle = (first + last) / 2
            if songs[middle].upperBound <= low { first = middle + 1 } else { last = middle }
        }
        var covered = 0.0
        var index = first
        while index < songs.count, songs[index].lowerBound < high {
            covered += max(0, min(high, songs[index].upperBound) - max(low, songs[index].lowerBound))
            index += 1
        }
        return min(max(covered / (high - low), 0), 1)
    }

    /// Fills `gains` with how much of the effect to hear at each of `count` frames from `start`.
    func fill(_ gains: UnsafeMutablePointer<Float>, for scope: InsertScope, from start: Int, count: Int, sampleRate: Double) {
        guard count > 0 else { return }
        guard scope != .everything, !songs.isEmpty || scope == .songs else {
            gains.update(repeating: scope == .songs ? 0 : 1, count: count)
            return
        }
        // Worked out every 64 frames, which is far finer than any fade, and drawn straight in between.
        let step = 64
        var previous = amount(for: scope, at: Double(start) / sampleRate)
        var offset = 0
        while offset < count {
            let length = min(step, count - offset)
            let next = amount(for: scope, at: Double(start + offset + length) / sampleRate)
            if previous == next {
                (gains + offset).update(repeating: previous, count: length)
            } else {
                let slope = (next - previous) / Float(length)
                for index in 0..<length {
                    gains[offset + index] = previous + slope * Float(index)
                }
            }
            previous = next
            offset += length
        }
    }
}
