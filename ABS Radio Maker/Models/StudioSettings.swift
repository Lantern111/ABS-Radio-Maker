import Foundation

/// How the character sits in the scene and how lively it is. Saved between launches.
struct StudioSettings: Codable, Equatable, Sendable {
    /// Moves the character sideways, as a fraction of the screen width. Positive is to the right.
    var characterOffsetX = 0.0
    /// Moves the character up or down, as a fraction of the screen height. Positive is down.
    var characterOffsetY = 0.0
    /// 1 is the drawing's own size.
    var characterScale = 1.0
    /// How much the character sways, from 0 (still) to 2 (twice the usual).
    var swayAmount = 1.0
    /// How easily the mouth opens, from 0 (only for loud speech) to 1 (for quiet speech too).
    var mouthSensitivity = 0.5
    var framesPerSecond = 30

    static let frameRateChoices = [24, 30]

    private static let key = "studioSettings"

    static func load() -> StudioSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(StudioSettings.self, from: data)
        else { return StudioSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
