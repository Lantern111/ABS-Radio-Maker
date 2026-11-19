import SwiftUI

/// Where the character sits and how lively it is.
struct CharacterPanel: View {
    @Bindable var studio: Studio

    var body: some View {
        Form {
            Section("위치와 크기") {
                SettingSlider(title: "가로 위치", value: $studio.settings.characterOffsetX, range: -0.5...0.5, format: percent)
                SettingSlider(title: "세로 위치", value: $studio.settings.characterOffsetY, range: -0.5...0.5, format: percent)
                SettingSlider(title: "크기", value: $studio.settings.characterScale, range: 0.4...1.6, format: { "\(Int(($0 * 100).rounded()))%" })
            }

            Section {
                SettingSlider(title: "흔들림", value: $studio.settings.swayAmount, range: 0...2, format: { $0 == 0 ? "멈춤" : String(format: "%.1f배", $0) })
                SettingSlider(title: "입 반응", value: $studio.settings.mouthSensitivity, range: 0...1, format: { "\(Int(($0 * 100).rounded()))" })
            } header: {
                Text("움직임")
            } footer: {
                Text("입 반응을 올리면 작은 목소리에도 입이 더 자주 벌어져요.")
            }

            Section {
                Picker("노래 들을 때", selection: $studio.settings.listeningEyes) {
                    ForEach(ListeningEyes.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } footer: {
                Text("노래가 나오는 동안은 리듬에 맞춰 몸을 흔들어요. \"가끔 눈 감기\"는 대부분 눈을 뜨고 듣다가 가끔 몇 초씩 눈을 감아요.")
            }

            Section {
                Picker("화면 속도", selection: $studio.settings.framesPerSecond) {
                    ForEach(StudioSettings.frameRateChoices, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
            } footer: {
                Text("24 fps는 영상을 더 빨리 만들고, 30 fps는 움직임이 더 부드러워요.")
            }

            Section {
                Button("모두 기본값으로") {
                    studio.settings = StudioSettings()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func percent(_ value: Double) -> String {
        let rounded = Int((value * 100).rounded())
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
    }
}

struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}
