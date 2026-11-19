import SwiftUI

/// Play and pause, the time, zoom, and the timeline of talk and songs.
struct TransportBar: View {
    let studio: Studio
    @State private var viewport = TimelineViewport()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    studio.player.togglePlayback()
                } label: {
                    Image(systemName: studio.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!studio.hasRecording)
                .help("재생 / 일시정지 (스페이스바)")

                Text("\(TimeText.format(studio.player.time)) / \(TimeText.format(studio.player.duration))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                if let selection = viewport.selection {
                    Text("선택 \(TimeText.format(selection.lowerBound))–\(TimeText.format(selection.upperBound))")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button("노래로") {
                        studio.setSegment(from: selection.lowerBound, to: selection.upperBound, isMusic: true)
                        viewport.selection = nil
                    }
                    .tint(Color(nsColor: TimelineNSView.songColor))
                    Button("말하기로") {
                        studio.setSegment(from: selection.lowerBound, to: selection.upperBound, isMusic: false)
                        viewport.selection = nil
                    }
                    .tint(Color(nsColor: TimelineNSView.talkColor))
                    Button("선택 해제", systemImage: "xmark") { viewport.selection = nil }
                        .labelStyle(.iconOnly)
                    Divider().frame(height: 16)
                } else {
                    Legend(color: Color(nsColor: TimelineNSView.talkColor), label: "말하기")
                    Legend(color: Color(nsColor: TimelineNSView.songColor), label: "노래")
                    Divider().frame(height: 16)
                }

                Button("축소", systemImage: "minus.magnifyingglass") { viewport.zoom(by: 1 / 1.6) }
                    .keyboardShortcut("-", modifiers: .command)
                    .help("타임라인 축소 (⌘−)")
                    .disabled(!studio.hasRecording || viewport.isShowingAll)
                Button("확대", systemImage: "plus.magnifyingglass") {
                    viewport.zoom(by: 1.6, around: studio.player.time)
                }
                .keyboardShortcut("=", modifiers: .command)
                .help("재생 위치를 중심으로 확대 (⌘+)")
                .disabled(!studio.hasRecording)
                Button("전체", systemImage: "arrow.left.and.right") { viewport.showAll() }
                    .keyboardShortcut("0", modifiers: .command)
                    .help("녹음 전체 보기 (⌘0)")
                    .disabled(!studio.hasRecording || viewport.isShowingAll)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)

            TimelineEditor(studio: studio, viewport: viewport)
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))

            Text("가로로 스크롤해서 이동하고, 핀치하거나 ⌘를 누른 채 스크롤해서 확대해요. 색 띠의 경계를 끌어 옮기고, 띠를 클릭하거나 끌어 선택한 뒤 \"노래로\"·\"말하기로\"를 누르세요. 우클릭으로도 바꿀 수 있어요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(studio.hasRecording ? 1 : 0)
        }
        .padding(12)
        .onChange(of: studio.recordingURL) {
            viewport.showAll()
            viewport.selection = nil
        }
    }
}

private struct Legend: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum TimeText {
    /// "1:05", or "1:05.3" when tenths of a second matter.
    static func format(_ seconds: Double, precise: Bool = false) -> String {
        let seconds = max(0, seconds)
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        var text = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
        if precise {
            text += String(format: ".%d", Int((seconds * 10).rounded(.down)) % 10)
        }
        return text
    }
}
