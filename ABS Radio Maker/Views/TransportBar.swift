import SwiftUI

/// Play and pause, the time, the editing tools, zoom, and the timeline of talk and songs.
struct TransportBar: View {
    @Bindable var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PlayButton(player: studio.player, isEnabled: studio.hasRecording)
                PlaybackTime(player: studio.player)

                Divider().frame(height: 16)

                Picker("도구", selection: Binding(get: { studio.timeline.tool }, set: { studio.timeline.tool = $0 })) {
                    Label("선택 (A)", systemImage: "cursorarrow").tag(TimelineTool.select)
                    Label("자르기 (B)", systemImage: "scissors").tag(TimelineTool.blade)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("선택 도구 (A) / 자르기 도구 (B): 자르기 도구로 색 띠를 클릭하면 그 자리에서 구간이 나뉘어요")

                Button("재생 위치에서 자르기", systemImage: "square.split.2x1") {
                    studio.splitSegment(at: studio.player.time)
                }
                .help("재생 위치에서 구간을 둘로 나눠요 (⌘B)")
                .disabled(!studio.hasRecording)

                Spacer()

                SelectionControls(studio: studio)

                Divider().frame(height: 16)

                Button("축소", systemImage: "minus.magnifyingglass") { studio.timeline.zoom(by: 1 / 1.6) }
                    .help("타임라인 축소 (⌘−)")
                    .disabled(!studio.hasRecording || studio.timeline.isShowingAll)
                Button("확대", systemImage: "plus.magnifyingglass") {
                    studio.timeline.zoom(by: 1.6, around: studio.player.time)
                }
                .help("재생 위치를 중심으로 확대 (⌘=)")
                .disabled(!studio.hasRecording)
                Button("전체", systemImage: "arrow.left.and.right") { studio.timeline.showAll() }
                    .help("녹음 전체 보기 (⇧Z)")
                    .disabled(!studio.hasRecording || studio.timeline.isShowingAll)
                Button("단축키", systemImage: "keyboard") { studio.showsShortcuts = true }
                    .help("키보드 단축키 보기")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .controlSize(.small)

            TimelineEditor(studio: studio)
                .frame(height: 118)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))

            Text(studio.timeline.tool == .blade
                ? "자르기 도구: 색 띠나 파형을 클릭하면 그 자리에서 구간이 나뉘어요. 나눈 조각을 클릭해 선택하고 1(말하기)이나 2(노래)를 누르세요. A를 누르면 선택 도구로 돌아가요."
                : "색 띠를 클릭하거나 끌어서 선택하고 1(말하기)·2(노래)를 누르거나 우클릭하세요. 경계는 끌어서 옮겨요. 짧은 멘트는 B(자르기)로 나눠서 지정해요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(studio.hasRecording ? 1 : 0)
        }
        .padding(12)
        .onChange(of: studio.recordingURL) {
            studio.timeline.showAll()
            studio.timeline.selection = nil
        }
    }
}

/// Reads the playback position on its own, so only this updates 30 times a second while playing.
private struct PlaybackTime: View {
    let player: PreviewPlayer

    var body: some View {
        HStack(spacing: 6) {
            Text("\(TimeText.format(player.time, precise: true)) / \(TimeText.format(player.duration))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if player.isPlaying, player.rate != 1 {
                Text("\(Int(player.rate))×")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct PlayButton: View {
    let player: PreviewPlayer
    let isEnabled: Bool

    var body: some View {
        Button(player.isPlaying ? "일시정지" : "재생", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
            player.togglePlayback()
        }
        .help("재생 / 일시정지 (스페이스바)")
        .disabled(!isEnabled)
    }
}

/// With a selection: make it talk or a song. Without: the colors' meaning.
private struct SelectionControls: View {
    let studio: Studio

    var body: some View {
        if let selection = studio.timeline.selection {
            Text("선택 \(TimeText.format(selection.lowerBound, precise: true))–\(TimeText.format(selection.upperBound, precise: true))")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button {
                studio.setSegment(from: selection.lowerBound, to: selection.upperBound, isMusic: false)
            } label: {
                Text("말하기로 (1)")
            }
            .tint(Color(nsColor: TimelineNSView.talkColor))
            Button {
                studio.setSegment(from: selection.lowerBound, to: selection.upperBound, isMusic: true)
            } label: {
                Text("노래로 (2)")
            }
            .tint(Color(nsColor: TimelineNSView.songColor))
            Button("선택 해제", systemImage: "xmark") { studio.timeline.selection = nil }
                .help("선택 해제 (Esc)")
        } else {
            Legend(color: Color(nsColor: TimelineNSView.talkColor), label: "말하기")
            Legend(color: Color(nsColor: TimelineNSView.songColor), label: "노래")
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
