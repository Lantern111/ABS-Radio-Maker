import SwiftUI

/// The plug-ins on the recording, in order, with the output meter beside them, like a channel strip in Logic Pro.
struct PluginRack: View {
    let studio: Studio

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PluginSlots(chain: studio.plugins, applying: studio.applyingPlugins)
                .frame(maxWidth: .infinity)
            LevelMeter(player: studio.player, target: studio.audioOptions.normalizesLoudness ? studio.audioOptions.targetLoudness : nil)
                .frame(width: 92)
        }
    }
}

private struct PluginSlots: View {
    let chain: PluginChain
    let applying: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(chain.loaded.enumerated()), id: \.element.id) { index, plugin in
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Button {
                        chain.openEditor(of: plugin)
                    } label: {
                        Text(verbatim: plugin.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(plugin.isOn ? Color.primary : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(plugin.name) 창 열기")

                    Button {
                        chain.setOn(!plugin.isOn, for: plugin)
                    } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(plugin.isOn ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(plugin.isOn ? "끄기 (건너뛰기)" : "켜기")
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color.secondary.opacity(0.14), in: .rect(cornerRadius: 5))
                .contextMenu {
                    Button("위로") { chain.move(plugin, by: -1) }
                        .disabled(index == 0)
                    Button("아래로") { chain.move(plugin, by: 1) }
                        .disabled(index == chain.loaded.count - 1)
                    Divider()
                    Button("빼기", role: .destructive) { chain.remove(plugin) }
                }
            }

            Menu {
                ForEach(orderedManufacturers, id: \.self) { manufacturer in
                    Menu(manufacturer) {
                        ForEach(chain.available.filter { $0.manufacturer == manufacturer }) { plugin in
                            Button(plugin.name) { chain.add(plugin) }
                        }
                    }
                }
            } label: {
                Label(chain.isLoading ? "불러오는 중…" : "플러그인 추가", systemImage: "plus")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(Color.secondary.opacity(0.07), in: .rect(cornerRadius: 5))
            .disabled(chain.isLoading || chain.available.isEmpty)

            if chain.isLoading {
                Text("처음 쓰는 플러그인은 macOS가 이 앱에서 써도 되는지 물어봐요. 창이 뜨면 허용을 눌러 주세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let applying {
                HStack(spacing: 6) {
                    ProgressView(value: applying)
                        .controlSize(.small)
                    Text("내보내기에 적용 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if let failed = chain.pluginThatFailed {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(failed)을(를) 불러오지 못했어요.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("닫기", systemImage: "xmark") { chain.pluginThatFailed = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
        }
        .onAppear(perform: chain.findAvailablePlugins)
    }

    /// Apple's own effects last, after the plug-ins people install on purpose.
    private var orderedManufacturers: [String] {
        let all = chain.manufacturers
        return all.filter { $0 != "Apple" } + all.filter { $0 == "Apple" }
    }
}

/// Left and right output levels, peak and average, with the loudest moment held for a moment and a light for clipping,
/// and the loudness in LUFS beneath: momentary and over the last three seconds.
struct LevelMeter: View {
    let player: PreviewPlayer
    /// The loudness the export aims for, marked beside the readouts.
    let target: Double?

    private static let lowest: Float = -60
    private static let marks: [Float] = [0, -6, -12, -18, -24, -36, -48, -60]

    var body: some View {
        let reading = player.meter
        VStack(spacing: 6) {
            Button {
                player.resetClip()
            } label: {
                Text("클립")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(reading.clipped ? Color.white : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(reading.clipped ? Color.red : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help(reading.clipped ? "소리가 0 dBFS에 닿았어요. 클릭하면 꺼져요." : "소리가 0 dBFS에 닿으면 켜져요.")

            Canvas { context, size in
                draw(reading, in: &context, size: size)
            }
            .frame(height: 170)
            .accessibilityLabel(Text("출력 레벨"))
            .accessibilityValue(Text(String(format: "왼쪽 %.0f dB, 오른쪽 %.0f dB", reading.peak[0], reading.peak[1])))

            VStack(spacing: 2) {
                loudness("순간", reading.momentary)
                loudness("3초", reading.shortTerm)
                if let target {
                    Text(String(format: "목표 %.0f LUFS", target))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func loudness(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value.map { String(format: "%.1f", $0) } ?? "–")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(color(forLoudness: value))
        }
    }

    /// Green near the target, yellow a little off, red far off.
    private func color(forLoudness value: Double?) -> Color {
        guard let value, let target else { return .primary }
        let off = abs(value - target)
        return off <= 2 ? .green : off <= 5 ? .yellow : .red
    }

    private func position(of decibels: Float) -> CGFloat {
        CGFloat((min(max(decibels, Self.lowest), 0) - Self.lowest) / -Self.lowest)
    }

    private func draw(_ reading: MeterReading, in context: inout GraphicsContext, size: CGSize) {
        let scaleWidth: CGFloat = 22
        let barWidth: CGFloat = 12
        let gap: CGFloat = 4
        let height = size.height
        let left = (size.width - scaleWidth - barWidth * 2 - gap) / 2

        // Scale.
        for mark in Self.marks {
            let y = height - position(of: mark) * height
            let label = context.resolve(
                Text(verbatim: mark == 0 ? "0" : "\(Int(mark))")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(Color.secondary)
            )
            context.draw(label, at: CGPoint(x: left + scaleWidth - 4, y: min(max(y, 5), height - 5)), anchor: .trailing)
        }

        for channel in 0..<2 {
            let x = left + scaleWidth + CGFloat(channel) * (barWidth + gap)
            let track = CGRect(x: x, y: 0, width: barWidth, height: height)
            context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.secondary.opacity(0.15)))

            // Peak, coloured by zone: green, then yellow from -12 dB, red from -3 dB.
            let peakHeight = position(of: reading.peak[channel]) * height
            let zones: [(from: Float, to: Float, color: Color)] = [(-60, -12, .green), (-12, -3, .yellow), (-3, 0, .red)]
            for zone in zones {
                let bottom = position(of: zone.from) * height
                let top = min(position(of: zone.to) * height, peakHeight)
                guard top > bottom else { continue }
                context.fill(
                    Path(CGRect(x: x, y: height - top, width: barWidth, height: top - bottom)),
                    with: .color(zone.color.opacity(0.85))
                )
            }
            // Average level, as a brighter core.
            let rmsHeight = position(of: reading.rms[channel]) * height
            if rmsHeight > 0 {
                context.fill(
                    Path(CGRect(x: x + barWidth * 0.3, y: height - rmsHeight, width: barWidth * 0.4, height: rmsHeight)),
                    with: .color(.white.opacity(0.55))
                )
            }
            // The loudest lately.
            if reading.hold[channel] > Self.lowest {
                let y = height - position(of: reading.hold[channel]) * height
                context.fill(Path(CGRect(x: x, y: y - 1, width: barWidth, height: 2)), with: .color(.primary))
            }
        }
    }
}
