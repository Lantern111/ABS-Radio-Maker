import AppKit
import Sparkle
import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var studio: Studio { appDelegate.studio }

    var body: some Scene {
        Window("ABS Radio Maker", id: "studio") {
            ContentView(studio: studio)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updaterController.updater)
            }

            CommandGroup(replacing: .newItem) {
                Button("녹음 열기…", action: studio.chooseRecording)
                    .keyboardShortcut("o")
                    .disabled(studio.isBusy)
            }

            CommandGroup(after: .saveItem) {
                Button("영상 내보내기…", action: studio.exportVideo)
                    .keyboardShortcut("e")
                    .disabled(!studio.hasRecording || studio.isBusy)
                Button("음원 내보내기…", action: studio.exportAudio)
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!studio.hasRecording || studio.isBusy)
            }
        }

        Settings {
            SettingsView(updater: updaterController.updater)
        }
    }
}

/// Opens recordings dropped on the Dock icon or opened from Finder with "Open With".
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let studio = Studio()

    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first, !studio.isBusy else { return }
        studio.open(url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
