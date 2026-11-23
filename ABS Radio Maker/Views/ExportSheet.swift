import SwiftUI

/// Shows how far along an export is, then where the file went.
struct ExportSheet: View {
    let studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let export = studio.export {
                if let url = export.finishedURL {
                    Label("다 만들었어요", systemImage: "checkmark.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                    Text(url.lastPathComponent)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("Finder에서 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Button("닫기") { studio.export = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                } else if let message = export.errorMessage {
                    Label("만들지 못했어요", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(message)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if Feedback.isAvailable {
                            Button("버그 신고…") { Feedback.open(.bug, details: "내보내기 중 오류: \(message)") }
                        }
                        Spacer()
                        Button("닫기") { studio.export = nil }
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Text(export.message)
                        .font(.headline)
                    ProgressView(value: export.fraction)
                    HStack {
                        Text("\(Int((export.fraction * 100).rounded(.down)))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("취소", role: .cancel, action: studio.cancelExport)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}
