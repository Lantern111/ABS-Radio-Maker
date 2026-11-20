import CoreGraphics
import Foundation

/// How often the character shuts its eyes to enjoy a song.
enum ListeningEyes: String, Codable, CaseIterable, Identifiable, Sendable {
    case open
    case sometimes
    case often
    case always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "눈 뜨고 듣기"
        case .sometimes: "가끔 눈 감기"
        case .often: "자주 눈 감기"
        case .always: "계속 눈 감기"
        }
    }

    /// How long the eyes stay open between closed stretches, in seconds.
    var openSeconds: ClosedRange<Double> {
        switch self {
        case .often: 4...8
        default: 10...20
        }
    }

    /// How long each closed stretch lasts, in seconds.
    var closedSeconds: ClosedRange<Double> {
        switch self {
        case .often: 5...10
        default: 3...6
        }
    }
}

/// Where the corner cover goes: the inside of the frame on the studio wall, as fractions of the screen, measured from
/// the top left. The cover is fitted inside without cropping.
struct CoverFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// The frame on the right-hand wall of the default studio background.
    static let studioWall = CoverFrame(x: 0.8349, y: 0.3167, width: 0.1178, height: 0.2487)

    func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

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
    var listeningEyes = ListeningEyes.sometimes
    var framesPerSecond = 30
    var coverFrame = CoverFrame.studioWall

    static let frameRateChoices = [24, 30]

    init() {}

    /// Settings saved by an older version keep their values, and anything added since starts at its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = StudioSettings()
        characterOffsetX = try container.decodeIfPresent(Double.self, forKey: .characterOffsetX) ?? defaults.characterOffsetX
        characterOffsetY = try container.decodeIfPresent(Double.self, forKey: .characterOffsetY) ?? defaults.characterOffsetY
        characterScale = try container.decodeIfPresent(Double.self, forKey: .characterScale) ?? defaults.characterScale
        swayAmount = try container.decodeIfPresent(Double.self, forKey: .swayAmount) ?? defaults.swayAmount
        mouthSensitivity = try container.decodeIfPresent(Double.self, forKey: .mouthSensitivity) ?? defaults.mouthSensitivity
        listeningEyes = (try? container.decodeIfPresent(ListeningEyes.self, forKey: .listeningEyes)) ?? defaults.listeningEyes
        framesPerSecond = try container.decodeIfPresent(Int.self, forKey: .framesPerSecond) ?? defaults.framesPerSecond
        coverFrame = (try? container.decodeIfPresent(CoverFrame.self, forKey: .coverFrame)) ?? defaults.coverFrame
    }

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
