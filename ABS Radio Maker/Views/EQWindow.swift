import AppKit
import SwiftUI

/// The channel EQ, laid out like Logic Pro's Channel EQ: the spectrum of what's playing with the EQ curve over it, a
/// point for each band to drag, and the bands' numbers along the bottom. ⚙︎ swaps the spectrum for its settings.
struct EQWindow: View {
    @Bindable var studio: Studio
    @State private var selected: Int?
    @State private var showsSettings = false

    static let bandColors = SpectrumNSView.bandColors.map { Color(nsColor: $0) }

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            Group {
                if showsSettings {
                    SpectrumSettingsPanel(settings: $studio.spectrumSettings) {
                        showsSettings = false
                    }
                } else {
                    SpectrumDisplay(
                        player: studio.player,
                        settings: studio.spectrumSettings,
                        equalizer: studio.equalizer,
                        editsBands: true,
                        selected: selected,
                        onChange: { [studio] in studio.setBand($0) },
                        onSelect: { selected = $0 }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bands
        }
        .frame(minWidth: 780, minHeight: 440)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Toggle("EQ 켜기", isOn: $studio.equalizer.isOn)
                .toggleStyle(.switch)
                .controlSize(.small)

            Picker("적용 구간", selection: $studio.equalizer.scope) {
                ForEach(InsertScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("EQ를 걸 곳: 녹음 전체, 말하는 구간만, 노래 구간만")

            if studio.equalizer.scope != .everything {
                Picker("전환", selection: $studio.insertTransition) {
                    ForEach(Studio.transitionChoices, id: \.self) { seconds in
                        Text(Self.seconds(seconds)).tag(seconds)
                    }
                }
                .fixedSize()
                .help("구간이 바뀔 때 EQ가 서서히 걸리고 풀리는 시간")
            }

            Spacer(minLength: 8)

            Text("점을 끌면 주파수·게인, 스크롤하면 Q, 두 번 클릭하면 켜고 꺼요")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Button("초기화") {
                studio.resetEqualizer()
                selected = nil
            }
            .help("모든 밴드를 끄고 평평하게 되돌려요")

            Button {
                showsSettings.toggle()
            } label: {
                Image(systemName: showsSettings ? "waveform.path.ecg" : "gearshape")
            }
            .help(showsSettings ? "스펙트럼으로 돌아가기" : "스펙트럼 설정")
        }
    }

    private var bands: some View {
        HStack(spacing: 0) {
            ForEach(studio.equalizer.bands) { band in
                BandColumn(
                    band: band,
                    color: Self.bandColors[band.id % Self.bandColors.count],
                    isSelected: selected == band.id,
                    set: studio.setBand,
                    select: { selected = band.id }
                )
                .equatable()
                if band.id < studio.equalizer.bands.count - 1 {
                    Divider()
                }
            }
        }
        .frame(height: 118)
    }

    static func seconds(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(value))초" : String(format: "%.1f초", value)
    }
}

/// One band's switch and numbers. Only the band being changed redraws while a point is dragged.
private struct BandColumn: View, Equatable {
    let band: EQBand
    let color: Color
    let isSelected: Bool
    let set: (EQBand) -> Void
    let select: () -> Void

    static func == (lhs: BandColumn, rhs: BandColumn) -> Bool {
        lhs.band == rhs.band && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                var changed = band
                changed.isOn.toggle()
                set(changed)
                select()
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(band.isOn ? color : Color.clear)
                        .overlay(Circle().stroke(color, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                    Text(band.kind.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(band.isOn ? Color.primary : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(band.isOn ? "끄기" : "켜기")

            field("Hz", value: band.frequency, digits: 0) { $0.frequency = $1 }
            field("dB", value: band.gain, digits: 1) { $0.gain = $1 }
                .disabled(!band.kind.hasGain)
                .opacity(band.kind.hasGain ? 1 : 0.35)
            field("Q", value: band.q, digits: 2) { $0.q = $1 }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(isSelected ? color.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
    }

    private func field(_ unit: String, value: Double, digits: Int, change: @escaping (inout EQBand, Double) -> Void) -> some View {
        HStack(spacing: 3) {
            TextField(
                unit,
                value: Binding(get: { value }, set: { newValue in
                    var changed = band
                    change(&changed, newValue)
                    changed.isOn = true
                    set(changed)
                }),
                format: .number.grouping(.never).precision(.fractionLength(digits))
            )
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.callout.monospacedDigit())
            .frame(width: 62)
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
    }
}

/// The small EQ display at the top of the channel strip: what's playing, and the EQ's curve. Clicking opens the window.
struct EQThumbnail: View {
    let studio: Studio
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let equalizer = studio.equalizer
        // The small display always draws a line; bars at this size are too busy.
        let settings = { var settings = studio.spectrumSettings; settings.style = .line; return settings }()

        Button {
            openWindow(id: "eq")
        } label: {
            SpectrumDisplay(player: studio.player, settings: settings, equalizer: equalizer)
                .frame(height: 66)
                .overlay(alignment: .topLeading) {
                    Text(equalizer.isOn ? "EQ" : "EQ 꺼짐")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(4)
                }
                .overlay(alignment: .topTrailing) {
                    if equalizer.scope != .everything {
                        Image(systemName: equalizer.scope.systemImage)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color(nsColor: SpectrumNSView.curveColor))
                            .padding(4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("채널 EQ 열기 (⌥⌘E)")
        .contextMenu {
            Button(equalizer.isOn ? "EQ 끄기" : "EQ 켜기") { studio.equalizer.isOn.toggle() }
            Picker("적용 구간", selection: Binding(get: { studio.equalizer.scope }, set: { studio.equalizer.scope = $0 })) {
                ForEach(InsertScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage).tag(scope)
                }
            }
            Divider()
            Button("채널 EQ 열기") { openWindow(id: "eq") }
        }
    }
}
