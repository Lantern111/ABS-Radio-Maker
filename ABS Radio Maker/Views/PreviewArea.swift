import SwiftUI

/// The scene as it will look in the video, moving with the sound while it plays.
struct PreviewArea: View {
    let studio: Studio

    var body: some View {
        ZStack {
            Color.black

            if studio.hasRecording {
                // Follows the player's position, which updates 30 times a second while playing.
                SceneView(studio: studio)
            } else {
                // Without a recording the character idles on a loop, so layers can be arranged before anything is open.
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    SceneView(studio: studio, idleTime: context.date.timeIntervalSinceReferenceDate)
                }
            }

            overlay
        }
        .frame(minHeight: 340)
    }

    @ViewBuilder private var overlay: some View {
        switch studio.phase {
        case .empty:
            // Kept low, out of the character's way, so the layers can be arranged while it shows.
            HStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 26))
                VStack(alignment: .leading, spacing: 2) {
                    Text("녹음 파일을 여기에 끌어다 놓으세요")
                        .font(.headline)
                    Text("WAV, MP3, M4A 파일을 쓸 수 있어요")
                        .foregroundStyle(.secondary)
                }
                Button("녹음 파일 열기…", action: studio.chooseRecording)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(20)
        case .working(let message, let fraction):
            VStack(spacing: 12) {
                Text(message)
                    .font(.headline)
                if let fraction {
                    ProgressView(value: fraction)
                        .frame(width: 260)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        case .ready:
            EmptyView()
        }
    }
}
