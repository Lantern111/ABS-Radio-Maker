import Foundation

/// One picture the video is built from. Most come with a stand-in inside the app, which people can replace with their
/// own drawing. Every picture is drawn to fill the whole 16:9 screen, so a replacement should be drawn on a canvas the
/// same shape as the background, with the transparent parts left clear.
enum LayerSlot: String, CaseIterable, Identifiable, Codable, Sendable {
    case background
    case character
    case desk
    case mouthHalf
    case mouthOpen
    case blink
    case listening
    case musicBackground
    case cover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "배경"
        case .character: "캐릭터 (입 다묾)"
        case .desk: "책상과 마이크"
        case .mouthHalf: "입 조금 벌림"
        case .mouthOpen: "입 크게 벌림"
        case .blink: "눈 감음 (깜빡임)"
        case .listening: "노래 들을 때"
        case .musicBackground: "노래 나올 때 배경"
        case .cover: "코너 표지"
        }
    }

    var detail: String {
        switch self {
        case .background: "맨 뒤에 깔리는 그림"
        case .character: "말하지 않을 때의 기본 모습"
        case .desk: "캐릭터 앞에 놓이는 그림"
        case .mouthHalf: "작게 말할 때"
        case .mouthOpen: "크게 말할 때"
        case .blink: "눈을 깜빡일 때, 노래를 들으며 눈 감을 때"
        case .listening: "비워 두면 눈 감음 그림을 써요"
        case .musicBackground: "비워 두면 기본 배경을 그대로 써요"
        case .cover: "배경의 액자 안에 들어가요"
        }
    }

    /// The stand-in that ships inside the app, or nil for a slot that stays empty until someone fills it.
    var defaultResource: String? {
        switch self {
        case .background: "default_background"
        case .character: "default_character"
        case .desk: "default_desk"
        case .mouthHalf: "default_character_mouth_half"
        case .mouthOpen: "default_character_mouth_open"
        case .blink: "default_character_blink"
        case .listening, .musicBackground, .cover: nil
        }
    }

    /// Whether this is one of the character's drawings, which move together with the character's position and sway.
    var isCharacterPose: Bool {
        switch self {
        case .character, .mouthHalf, .mouthOpen, .blink, .listening: true
        case .background, .desk, .musicBackground, .cover: false
        }
    }

    static let sections: [(title: String, slots: [LayerSlot])] = [
        ("기본 레이어", [.background, .character, .desk]),
        ("캐릭터 표정", [.mouthHalf, .mouthOpen, .blink, .listening]),
        ("코너 표지", [.cover]),
        ("노래 구간", [.musicBackground]),
    ]
}
