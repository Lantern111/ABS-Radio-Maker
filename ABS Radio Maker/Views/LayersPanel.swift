import SwiftUI
import UniformTypeIdentifiers

/// Every picture the video is built from, each replaceable by dropping in a new one.
struct LayersPanel: View {
    let library: LayerLibrary
    @Binding var coverFrame: CoverFrame

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("그림을 끌어다 놓거나 \"바꾸기\"를 누르면 바로 바뀌어요. 배경과 같은 16:9 캔버스에 그리고, 비어 있는 곳은 투명하게 둔 PNG가 가장 잘 맞아요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(LayerSlot.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.headline)
                        ForEach(section.slots) { slot in
                            LayerRow(library: library, slot: slot)
                            if slot == .cover {
                                CoverFrameControls(frame: $coverFrame)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

private struct LayerRow: View {
    let library: LayerLibrary
    let slot: LayerSlot

    @State private var isTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(slot.title)
                        .font(.body.weight(.medium))
                    if library.customSlots.contains(slot) {
                        Text("직접 넣음")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                Text(slot.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button("바꾸기…", action: choose)
                    if library.customSlots.contains(slot) {
                        Button(slot.defaultResource == nil ? "비우기" : "기본으로") {
                            library.reset(slot)
                        }
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isTargeted ? Color.accentColor : .clear, lineWidth: 2)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            replace(with: url)
            return true
        } isTargeted: { isTargeted = $0 }
        .alert("그림을 바꾸지 못했어요", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var thumbnail: some View {
        ZStack {
            // A checkerboard shows which parts are see-through.
            Checkerboard()
            if let image = library.images[slot] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = LayerLibrary.acceptedTypes
        panel.message = "\"\(slot.title)\"에 쓸 그림을 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replace(with: url)
    }

    private func replace(with url: URL) {
        do {
            try library.replace(slot, with: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.85)))
            for row in 0..<Int(size.height / square) + 1 {
                for column in 0..<Int(size.width / square) + 1 where (row + column).isMultiple(of: 2) {
                    context.fill(
                        Path(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)),
                        with: .color(Color(white: 0.72))
                    )
                }
            }
        }
    }
}

/// Lines the cover up with the frame, for a background whose frame is somewhere else.
private struct CoverFrameControls: View {
    @Binding var frame: CoverFrame
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup("액자 위치 맞추기", isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: 8) {
                Text("배경을 바꿔서 액자 자리가 달라졌을 때만 맞추면 돼요. 표지는 잘리지 않게 액자 안에 맞춰 들어가요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SettingSlider(title: "가로 위치", value: $frame.x, range: 0...0.95, format: percent)
                SettingSlider(title: "세로 위치", value: $frame.y, range: 0...0.95, format: percent)
                SettingSlider(title: "너비", value: $frame.width, range: 0.03...0.6, format: percent)
                SettingSlider(title: "높이", value: $frame.height, range: 0.03...0.9, format: percent)
                Button("기본 배경의 액자에 맞추기") { frame = .studioWall }
                    .controlSize(.small)
                    .disabled(frame == .studioWall)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 8)
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
