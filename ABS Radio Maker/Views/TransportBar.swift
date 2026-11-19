import SwiftUI

/// Play and pause, the time, and the timeline showing where the talk and songs are.
struct TransportBar: View {
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    studio.player.togglePlayback()
                } label: {
                    Image(systemName: studio.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!studio.hasRecording)
                .help("재생 / 일시정지 (스페이스바)")

                TimelineView(.animation(minimumInterval: 0.1, paused: !studio.player.isPlaying)) { _ in
                    let _ = studio.player.seekRevision
                    Text("\(TimeText.format(studio.player.currentTime)) / \(TimeText.format(studio.player.duration))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Legend(color: TimelineStrip.talkColor, label: "말하기")
                Legend(color: TimelineStrip.songColor, label: "노래")
            }

            TimelineStrip(studio: studio)
                .frame(height: 54)
                .opacity(studio.hasRecording ? 1 : 0.35)
        }
        .padding(12)
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

/// The whole edited recording: its level, which parts are talk and which are songs, and where playback is. Click or
/// drag to move around.
struct TimelineStrip: View {
    let studio: Studio

    static let talkColor = Color(red: 0.33, green: 0.56, blue: 0.95)
    static let songColor = Color(red: 0.93, green: 0.42, blue: 0.62)

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !studio.player.isPlaying)) { _ in
                let _ = studio.player.seekRevision
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    guard studio.player.duration > 0 else { return }
                    let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                    studio.player.seek(to: fraction * studio.player.duration)
                }
            )
        }
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let duration = studio.performance.duration
        guard duration > 0, studio.hasRecording else { return }

        for segment in studio.performance.segments {
            let x = segment.start / duration * size.width
            let width = max((segment.end - segment.start) / duration * size.width, 1)
            let color = segment.isMusic ? Self.songColor : Self.talkColor
            context.fill(Path(CGRect(x: x, y: 0, width: width, height: size.height)), with: .color(color.opacity(0.28)))
        }

        let peaks = studio.overview
        if !peaks.isEmpty {
            let barWidth = size.width / CGFloat(peaks.count)
            var path = Path()
            for (index, peak) in peaks.enumerated() {
                let height = max(CGFloat(peak) * (size.height - 6), 1)
                path.addRect(CGRect(x: CGFloat(index) * barWidth, y: (size.height - height) / 2, width: max(barWidth - 0.5, 0.5), height: height))
            }
            context.fill(path, with: .color(.primary.opacity(0.45)))
        }

        let playhead = studio.player.duration > 0 ? studio.player.currentTime / studio.player.duration * size.width : 0
        context.fill(Path(CGRect(x: playhead - 1, y: 0, width: 2, height: size.height)), with: .color(.primary))
    }
}

enum TimeText {
    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
