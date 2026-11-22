import Foundation

/// Which stretches of the recording an effect works on. Where the stretch changes, the effect fades in or out over
/// the transition time instead of switching at once.
enum InsertScope: String, Codable, CaseIterable, Sendable {
    case everything
    case talk
    case songs

    var title: String {
        switch self {
        case .everything: "전체"
        case .talk: "말하기만"
        case .songs: "노래만"
        }
    }

    var systemImage: String {
        switch self {
        case .everything: "waveform"
        case .talk: "mic.fill"
        case .songs: "music.note"
        }
    }

    /// Runs of neighbouring items that share a scope, in order. They're processed together and faded together.
    static func groups<Item>(_ items: [Item], scope: (Item) -> InsertScope) -> [(scope: InsertScope, items: [Item])] {
        var groups: [(scope: InsertScope, items: [Item])] = []
        for item in items {
            let itemScope = scope(item)
            if let last = groups.last, last.scope == itemScope {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((itemScope, [item]))
            }
        }
        return groups
    }
}

/// One band of the channel EQ, laid out like Logic Pro's Channel EQ.
struct EQBand: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case lowCut
        case lowShelf
        case bell
        case highShelf
        case highCut

        var title: String {
            switch self {
            case .lowCut: "로우컷"
            case .lowShelf: "로우셸프"
            case .bell: "벨"
            case .highShelf: "하이셸프"
            case .highCut: "하이컷"
            }
        }

        /// Cuts have no gain of their own; only their frequency and Q matter.
        var hasGain: Bool { self != .lowCut && self != .highCut }
    }

    var id: Int
    var kind: Kind
    var isOn: Bool
    /// Hz.
    var frequency: Double
    /// dB, from -24 to +24.
    var gain: Double
    /// Width: higher is narrower. For the cuts and shelves, how sharp the corner is; 0.71 is no bump.
    var q: Double

    static let lowestFrequency = 20.0
    static let highestFrequency = 20_000.0
    static let gainRange = -24.0...24.0
    /// What Apple's EQ can do: its bandwidth goes from 0.05 to 5 octaves.
    static let qRange = 0.2...12.0

    /// How much the band raises or lowers a frequency, in dB, at a sample rate. These are the same filters Apple's EQ
    /// runs (the Audio EQ Cookbook's), so the curve on screen is the sound.
    func response(at frequency: Double, sampleRate: Double) -> Double {
        guard isOn else { return 0 }
        let (b, a) = coefficients(sampleRate: sampleRate)
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let numeratorReal = b.0 + b.1 * c1 + b.2 * c2
        let numeratorImaginary = -(b.1 * s1 + b.2 * s2)
        let denominatorReal = a.0 + a.1 * c1 + a.2 * c2
        let denominatorImaginary = -(a.1 * s1 + a.2 * s2)
        let numerator = numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        let denominator = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        return 10 * log10(max(numerator, 1e-30) / max(denominator, 1e-30))
    }

    private func coefficients(sampleRate: Double) -> (b: (Double, Double, Double), a: (Double, Double, Double)) {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.49) / sampleRate
        let cosine = cos(w0)
        // Apple's EQ takes a width in octaves and widens it toward the top of the range, as the Cookbook's octave
        // form does, so its Q there is a little lower than the number says.
        let alpha = sin(w0) * sinh(asinh(1 / (2 * q)) * w0 / sin(w0))
        let amplitude = pow(10, gain / 40)
        switch kind {
        case .bell:
            return ((1 + alpha * amplitude, -2 * cosine, 1 - alpha * amplitude),
                    (1 + alpha / amplitude, -2 * cosine, 1 - alpha / amplitude))
        case .lowShelf:
            let s = 2 * sqrt(amplitude) * alpha
            let up = amplitude + 1, down = amplitude - 1
            return ((amplitude * (up - down * cosine + s), 2 * amplitude * (down - up * cosine), amplitude * (up - down * cosine - s)),
                    (up + down * cosine + s, -2 * (down + up * cosine), up + down * cosine - s))
        case .highShelf:
            let s = 2 * sqrt(amplitude) * alpha
            let up = amplitude + 1, down = amplitude - 1
            return ((amplitude * (up + down * cosine + s), -2 * amplitude * (down + up * cosine), amplitude * (up + down * cosine - s)),
                    (up - down * cosine + s, 2 * (down - up * cosine), up - down * cosine - s))
        case .lowCut:
            return (((1 + cosine) / 2, -(1 + cosine), (1 + cosine) / 2), (1 + alpha, -2 * cosine, 1 - alpha))
        case .highCut:
            return (((1 - cosine) / 2, 1 - cosine, (1 - cosine) / 2), (1 + alpha, -2 * cosine, 1 - alpha))
        }
    }

    /// Apple's EQ takes the width in octaves.
    var bandwidth: Double {
        2 / log(2) * asinh(1 / (2 * q))
    }

    func clamped() -> EQBand {
        var band = self
        band.frequency = min(max(frequency, Self.lowestFrequency), Self.highestFrequency)
        band.gain = min(max(gain, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        band.q = min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound)
        return band
    }
}

/// The channel EQ's bands, whether it's on, and where it works. Saved between launches, like a channel strip's settings.
struct EQSettings: Codable, Equatable, Sendable {
    var isOn = true
    var bands: [EQBand] = EQSettings.standardBands
    var scope = InsertScope.everything

    /// Off and flat, as Logic Pro's Channel EQ starts.
    static let standardBands: [EQBand] = [
        EQBand(id: 0, kind: .lowCut, isOn: false, frequency: 80, gain: 0, q: 0.71),
        EQBand(id: 1, kind: .lowShelf, isOn: false, frequency: 120, gain: 0, q: 0.71),
        EQBand(id: 2, kind: .bell, isOn: false, frequency: 250, gain: 0, q: 1.1),
        EQBand(id: 3, kind: .bell, isOn: false, frequency: 800, gain: 0, q: 1.1),
        EQBand(id: 4, kind: .bell, isOn: false, frequency: 2_500, gain: 0, q: 1.1),
        EQBand(id: 5, kind: .bell, isOn: false, frequency: 6_000, gain: 0, q: 1.1),
        EQBand(id: 6, kind: .highShelf, isOn: false, frequency: 10_000, gain: 0, q: 0.71),
        EQBand(id: 7, kind: .highCut, isOn: false, frequency: 18_000, gain: 0, q: 0.71),
    ]

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        bands = try container.decodeIfPresent([EQBand].self, forKey: .bands) ?? Self.standardBands
        scope = try container.decodeIfPresent(InsertScope.self, forKey: .scope) ?? .everything
    }

    /// Whether the EQ changes the sound at all, so it can be left out when it doesn't.
    var isActive: Bool {
        isOn && bands.contains { $0.isOn && (!$0.kind.hasGain || abs($0.gain) > 0.01) }
    }

    /// The whole EQ's effect on a frequency, in dB.
    func response(at frequency: Double, sampleRate: Double) -> Double {
        guard isOn else { return 0 }
        return bands.reduce(0) { $0 + $1.response(at: frequency, sampleRate: sampleRate) }
    }

    func clamped() -> EQSettings {
        var settings = self
        settings.bands = bands.map { $0.clamped() }
        return settings
    }

    private static let key = "channelEQ"

    static func load() -> EQSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(EQSettings.self, from: data),
              settings.bands.count == standardBands.count
        else { return EQSettings() }
        return settings.clamped()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

/// How the spectrum analyzer looks, like MiniMeters' spectrum settings.
struct SpectrumSettings: Codable, Equatable, Sendable {
    enum Style: String, Codable, CaseIterable, Sendable {
        case line
        case bars
        case both

        var title: String {
            switch self {
            case .line: "FFT"
            case .bars: "Color Bars"
            case .both: "Both"
            }
        }
    }

    enum Scale: String, Codable, CaseIterable, Sendable {
        case mel
        case log
        case linear

        var title: String {
            switch self {
            case .mel: "Mel"
            case .log: "Log"
            case .linear: "Linear"
            }
        }
    }

    var style = Style.line
    /// 0 follows every change, near 1 moves slowly.
    var smoothing = 0.75
    /// dB per octave, turned around 1 kHz, so music's natural fall toward the highs reads as level.
    var tilt = 4.5
    var fftSize = 4096
    var scale = Scale.log

    static let fftSizes = [1024, 2048, 4096, 8192, 16384]
    static let smoothingRange = 0.0...0.95
    static let tiltRange = 0.0...6.0

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = SpectrumSettings()
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? standard.style
        smoothing = try container.decodeIfPresent(Double.self, forKey: .smoothing) ?? standard.smoothing
        tilt = try container.decodeIfPresent(Double.self, forKey: .tilt) ?? standard.tilt
        fftSize = try container.decodeIfPresent(Int.self, forKey: .fftSize) ?? standard.fftSize
        scale = try container.decodeIfPresent(Scale.self, forKey: .scale) ?? standard.scale
        if !Self.fftSizes.contains(fftSize) { fftSize = standard.fftSize }
    }

    private static let key = "spectrumSettings"

    static func load() -> SpectrumSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(SpectrumSettings.self, from: data)
        else { return SpectrumSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Where a frequency sits across the display, from 0 at 20 Hz to 1 at 20 kHz.
    func position(of frequency: Double) -> Double {
        let low = EQBand.lowestFrequency
        let high = EQBand.highestFrequency
        let f = min(max(frequency, low), high)
        switch scale {
        case .log:
            return log(f / low) / log(high / low)
        case .mel:
            return (Self.mel(f) - Self.mel(low)) / (Self.mel(high) - Self.mel(low))
        case .linear:
            return (f - low) / (high - low)
        }
    }

    /// The frequency at a place across the display, the reverse of `position(of:)`.
    func frequency(at position: Double) -> Double {
        let low = EQBand.lowestFrequency
        let high = EQBand.highestFrequency
        let p = min(max(position, 0), 1)
        switch scale {
        case .log:
            return low * pow(high / low, p)
        case .mel:
            let value = Self.mel(low) + p * (Self.mel(high) - Self.mel(low))
            return 700 * (pow(10, value / 2595) - 1)
        case .linear:
            return low + p * (high - low)
        }
    }

    private static func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
}
