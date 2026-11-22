import AppKit
import SwiftUI

/// Final Cut Pro's keys, for the main window. A local event monitor sees key presses before any control does, so they
/// work wherever the focus is in the window. ⌘Z and ⇧⌘Z go through the Edit menu as usual.
@MainActor final class KeyCommands {
    struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys }
    }

    static let sections: [(title: String, shortcuts: [Shortcut])] = [
        ("재생", [
            Shortcut(keys: "스페이스바", action: "재생 / 일시정지"),
            Shortcut(keys: "L", action: "재생 (다시 누르면 2배속)"),
            Shortcut(keys: "K", action: "정지"),
            Shortcut(keys: "J", action: "5초 뒤로"),
            Shortcut(keys: "← / →", action: "한 프레임 앞뒤로"),
            Shortcut(keys: "⇧← / ⇧→", action: "10프레임 앞뒤로"),
            Shortcut(keys: "↑ / ↓", action: "이전 / 다음 구간 경계로"),
            Shortcut(keys: "Home / End", action: "처음 / 끝으로"),
        ]),
        ("구간 편집", [
            Shortcut(keys: "A", action: "선택 도구"),
            Shortcut(keys: "B", action: "자르기(칼) 도구: 클릭한 곳을 잘라요"),
            Shortcut(keys: "⌘B", action: "재생 위치에서 자르기"),
            Shortcut(keys: "I / O", action: "선택 범위 시작 / 끝 지정"),
            Shortcut(keys: "X", action: "재생 위치의 구간 선택"),
            Shortcut(keys: "⌥X 또는 Esc", action: "선택 해제"),
            Shortcut(keys: "1", action: "선택한 구간(없으면 재생 위치 구간)을 말하기로"),
            Shortcut(keys: "2", action: "선택한 구간(없으면 재생 위치 구간)을 노래로"),
            Shortcut(keys: "⌘Z / ⇧⌘Z", action: "실행 취소 / 다시 실행"),
        ]),
        ("타임라인", [
            Shortcut(keys: "⌘= / ⌘−", action: "확대 / 축소"),
            Shortcut(keys: "⇧Z", action: "전체 보기"),
            Shortcut(keys: "⌘ + 스크롤, 핀치", action: "마우스 위치에서 확대 / 축소"),
        ]),
        ("화면", [
            Shortcut(keys: "⌥⌘I", action: "채널 스트립(플러그인·출력 레벨) 보기 / 숨기기"),
        ]),
        ("파일", [
            Shortcut(keys: "⌘O", action: "녹음 열기"),
            Shortcut(keys: "⌘E", action: "영상 내보내기"),
            Shortcut(keys: "⇧⌘E", action: "음원 내보내기"),
        ]),
    ]

    private var monitor: Any?
    private weak var studio: Studio?
    weak var window: NSWindow?

    func install(for studio: Studio) {
        self.studio = studio
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, with the event the window is about to handle.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private enum Key {
        static let space: UInt16 = 49
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let home: UInt16 = 115
        static let end: UInt16 = 119
    }

    /// Whether the key was one of ours. Keys that aren't go on to the window as usual.
    private func handle(_ event: NSEvent) -> Bool {
        guard let studio, let window, event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil else {
            return false
        }
        // Typing in a text field keeps its keys.
        if window.firstResponder is NSText { return false }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let player = studio.player
        let timeline = studio.timeline
        let hasRecording = studio.hasRecording
        let canEdit = hasRecording && !studio.isBusy

        switch (event.keyCode, modifiers) {
        case (Key.space, []):
            guard hasRecording else { return false }
            player.togglePlayback()
        case (Key.left, []), (Key.left, .shift):
            guard hasRecording else { return false }
            studio.step(frames: modifiers == .shift ? -10 : -1)
        case (Key.right, []), (Key.right, .shift):
            guard hasRecording else { return false }
            studio.step(frames: modifiers == .shift ? 10 : 1)
        case (Key.up, []):
            guard hasRecording else { return false }
            studio.jumpToBorder(forward: false)
        case (Key.down, []):
            guard hasRecording else { return false }
            studio.jumpToBorder(forward: true)
        case (Key.home, []):
            guard hasRecording else { return false }
            studio.jump(to: 0)
        case (Key.end, []):
            guard hasRecording else { return false }
            studio.jump(to: player.duration)
        case (Key.escape, []):
            timeline.selection = nil
            timeline.tool = .select
        default:
            switch (key, modifiers) {
            case ("l", []):
                guard hasRecording else { return false }
                player.playFaster()
            case ("k", []):
                player.pause()
            case ("j", []):
                guard hasRecording else { return false }
                studio.jump(to: player.time - 5)
            case ("a", []):
                timeline.tool = .select
            case ("b", []):
                timeline.tool = .blade
            case ("b", .command):
                guard canEdit else { return false }
                studio.splitSegment(at: player.time)
            case ("i", []):
                guard hasRecording else { return false }
                timeline.markStart(at: player.time)
            case ("o", []):
                guard hasRecording else { return false }
                timeline.markEnd(at: player.time)
            case ("x", []):
                guard hasRecording, let segment = studio.timelineSegment(at: player.time) else { return false }
                timeline.selection = segment.start...segment.end
            case ("x", .option):
                timeline.selection = nil
            case ("1", []), ("2", []):
                guard canEdit else { return false }
                let isMusic = key == "2"
                if let selection = timeline.selection {
                    studio.setSegment(from: selection.lowerBound, to: selection.upperBound, isMusic: isMusic)
                } else {
                    studio.setSegment(at: player.time, isMusic: isMusic)
                }
            case ("=", .command), ("+", .command), ("=", [.command, .shift]):
                guard hasRecording else { return false }
                timeline.zoom(by: 1.6, around: player.time)
            case ("-", .command):
                guard hasRecording else { return false }
                timeline.zoom(by: 1 / 1.6)
            case ("z", .shift):
                timeline.showAll()
            default:
                return false
            }
        }
        return true
    }
}

/// Hands over the window a view is in, once it's in one.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window { onWindow(window) }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let window = view.window { onWindow(window) }
    }
}

/// The list of keyboard shortcuts, from the Help menu or the keyboard button by the timeline.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("키보드 단축키")
                .font(.title2.weight(.semibold))
            Text("파이널컷 프로와 같은 키를 써요.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(KeyCommands.sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title)
                                .font(.headline)
                            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                                ForEach(section.shortcuts) { shortcut in
                                    GridRow {
                                        Text(shortcut.keys)
                                            .font(.body.monospaced())
                                            .frame(minWidth: 150, alignment: .leading)
                                        Text(shortcut.action)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520, height: 560)
    }
}
