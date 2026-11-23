import AppKit

/// Opens the feedback form in the browser for a bug report or a suggestion, with the app version, macOS version, and
/// kind of Mac already filled in so nobody has to look them up. The form passes reports on to the developer's email,
/// so the app needs no internet access of its own and shows no address. `Scripts/feedback-form.gs` makes the form.
enum Feedback {
    enum Kind {
        case bug
        case suggestion
    }

    /// The form's prefilled links, with placeholders the app fills in.
    private static let bugLink =
        "https://docs.google.com/forms/d/e/1FAIpQLSfnS4qldQEQKCwgX6OgdzREBJTIimu18BUjIGCUmZALqMWelw/viewform?usp=pp_url&entry.437681470=%EB%B2%84%EA%B7%B8+%EC%8B%A0%EA%B3%A0+/+Bug+report&entry.1478816623=DETAILS&entry.1305904062=APP_VERSION&entry.753895959=MACOS_VERSION&entry.2071216701=MAC_TYPE"
    private static let suggestionLink =
        "https://docs.google.com/forms/d/e/1FAIpQLSfnS4qldQEQKCwgX6OgdzREBJTIimu18BUjIGCUmZALqMWelw/viewform?usp=pp_url&entry.437681470=%EA%B0%9C%EC%84%A0+%EC%9A%94%EC%B2%AD+/+Suggestion&entry.1478816623=DETAILS&entry.1305904062=APP_VERSION&entry.753895959=MACOS_VERSION&entry.2071216701=MAC_TYPE"

    static var isAvailable: Bool { !bugLink.isEmpty && !suggestionLink.isEmpty }

    /// `details` starts the description, such as the message of an error that just appeared.
    static func open(_ kind: Kind, details: String = "") {
        let link = kind == .bug ? bugLink : suggestionLink
        guard !link.isEmpty else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let macOS = ProcessInfo.processInfo.operatingSystemVersion
        let values = [
            "DETAILS": details,
            "APP_VERSION": build.isEmpty ? version : "\(version) (\(build))",
            "MACOS_VERSION": "\(macOS.majorVersion).\(macOS.minorVersion).\(macOS.patchVersion)",
            "MAC_TYPE": macDescription,
        ]
        var address = link
        for (placeholder, value) in values {
            address = address.replacingOccurrences(of: placeholder, with: encoded(value))
        }
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Intel (iMac19,2)" or "Apple 실리콘 (Mac15,7)". Asks the hardware, so it's right even under translation.
    private static var macDescription: String {
        var isARM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let hasARM = sysctlbyname("hw.optional.arm64", &isARM, &size, nil, 0) == 0 && isARM == 1
        var modelSize = 0
        sysctlbyname("hw.model", nil, &modelSize, nil, 0)
        var model = [CChar](repeating: 0, count: max(modelSize, 1))
        sysctlbyname("hw.model", &model, &modelSize, nil, 0)
        let name = String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let chip = hasARM ? "Apple 실리콘" : "Intel"
        return name.isEmpty ? chip : "\(chip) (\(name))"
    }

    /// A value as it goes in a link's query.
    private static func encoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
