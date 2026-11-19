import Foundation

/// What to do to the recording before it goes in the video. The trim points are per recording; the rest is saved
/// between launches.
struct AudioEditOptions: Codable, Equatable, Sendable {
    /// Where the kept part starts, in seconds of the original recording.
    var trimStart = 0.0
    /// Where the kept part ends, in seconds of the original recording. Nil keeps everything to the end.
    var trimEnd: Double?

    var normalizesLoudness = true
    /// Integrated loudness to aim for, in LUFS. YouTube plays everything at about -14.
    var targetLoudness = -14.0
    /// Cuts the low rumble under 80 Hz: desk knocks, air conditioning, handling noise.
    var removesRumble = true
    /// Shortens pauses longer than about a second and a half to half a second.
    var shortensSilences = false
    var fadeIn = 1.0
    var fadeOut = 2.0

    static let loudnessChoices: [(value: Double, label: String)] = [
        (-14, "유튜브 (-14 LUFS)"),
        (-16, "팟캐스트 (-16 LUFS)"),
        (-23, "방송 기준 (-23 LUFS)"),
    ]

    private static let key = "audioEditOptions"

    static func load() -> AudioEditOptions {
        guard let data = UserDefaults.standard.data(forKey: key),
              var options = try? JSONDecoder().decode(AudioEditOptions.self, from: data)
        else { return AudioEditOptions() }
        // Trim points belong to one recording, so a new launch starts untrimmed.
        options.trimStart = 0
        options.trimEnd = nil
        return options
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
