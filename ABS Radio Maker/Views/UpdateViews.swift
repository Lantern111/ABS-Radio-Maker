import Combine
import Sparkle
import SwiftUI

/// The menu command that looks for a new version. It's dimmed while a check is already running.
struct CheckForUpdatesButton: View {
    let updater: SPUUpdater

    @StateObject private var availability = UpdateAvailability()

    var body: some View {
        Button("업데이트 확인…", action: updater.checkForUpdates)
            .disabled(!availability.canCheck)
            .onAppear { availability.follow(updater) }
    }
}

private final class UpdateAvailability: ObservableObject {
    @Published var canCheck = false

    func follow(_ updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }
}

struct SettingsView: View {
    let updater: SPUUpdater

    @State private var automaticallyUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        Form {
            Toggle("새 버전을 자동으로 받기", isOn: $automaticallyUpdates)
                .onChange(of: automaticallyUpdates) {
                    updater.automaticallyChecksForUpdates = automaticallyUpdates
                    updater.automaticallyDownloadsUpdates = automaticallyUpdates
                }
            LabeledContent("버전", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            Button("지금 업데이트 확인", action: updater.checkForUpdates)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}
