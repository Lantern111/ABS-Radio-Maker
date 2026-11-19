import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var studio: Studio
    @AppStorage("sidebarTab") private var tab = SidebarTab.layers

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                PreviewArea(studio: studio)
                Divider()
                TransportBar(studio: studio)
            }
            .frame(minWidth: 620)

            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)

                Divider()

                switch tab {
                case .layers: LayersPanel(library: studio.layers)
                case .character: CharacterPanel(studio: studio)
                case .audio: AudioPanel(studio: studio)
                }
            }
            .frame(minWidth: 320, idealWidth: 360, maxWidth: 460)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("녹음 열기", systemImage: "waveform.badge.plus", action: studio.chooseRecording)
                    .help("영상으로 만들 녹음 파일을 열어요 (⌘O)")
                    .disabled(studio.isBusy)

                Button("음원 내보내기", systemImage: "music.note", action: studio.exportAudio)
                    .help("다듬은 소리만 파일로 저장해요")
                    .disabled(!studio.hasRecording || studio.isBusy)

                Button(action: studio.exportVideo) {
                    Label("영상 내보내기", systemImage: "film")
                }
                .help("유튜브에 올릴 영상을 만들어요 (⌘E)")
                .buttonStyle(.borderedProminent)
                .disabled(!studio.hasRecording || studio.isBusy)
            }
        }
        .navigationTitle(studio.recordingURL?.lastPathComponent ?? "ABS Radio Maker")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { url in
                UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false
            }), !studio.isBusy else { return false }
            studio.open(url)
            return true
        }
        .sheet(isPresented: Binding(get: { studio.export != nil }, set: { if !$0 { studio.export = nil } })) {
            ExportSheet(studio: studio)
        }
        .alert(
            "문제가 생겼어요",
            isPresented: Binding(get: { studio.errorMessage != nil }, set: { if !$0 { studio.errorMessage = nil } })
        ) {
            Button("확인") {}
        } message: {
            Text(studio.errorMessage ?? "")
        }
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case layers
    case character
    case audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .layers: "레이어"
        case .character: "캐릭터"
        case .audio: "음원"
        }
    }
}
