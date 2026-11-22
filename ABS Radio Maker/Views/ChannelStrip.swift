import SwiftUI

/// A channel strip down the left of the window, as in Logic Pro's inspector: the EQ display at the top, then the
/// plug-ins in the order the sound passes through them, and the output meter below, with the loudness at the bottom.
struct ChannelStrip: View {
    @Bindable var studio: Studio

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("EQ")
            EQThumbnail(studio: studio)

            heading("플러그인")
                .padding(.top, 2)
            PluginSlots(chain: studio.plugins)

            if usesScopes {
                HStack(spacing: 4) {
                    Text("구간 전환")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Picker("구간 전환", selection: $studio.insertTransition) {
                        ForEach(Studio.transitionChoices, id: \.self) { seconds in
                            Text(EQWindow.seconds(seconds)).tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
                .help("말하기만·노래만 거는 효과가 구간이 바뀔 때 서서히 걸리고 풀리는 시간")
            }
            if let applying = studio.applyingPlugins {
                HStack(spacing: 6) {
                    ProgressView(value: applying)
                        .controlSize(.small)
                    Text("내보내기에 적용 중")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }

            Divider()
                .padding(.vertical, 2)

            heading("출력")
            LevelMeter(
                player: studio.player,
                target: studio.audioOptions.normalizesLoudness ? studio.audioOptions.targetLoudness : nil
            )
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var usesScopes: Bool {
        studio.equalizer.scope != .everything || studio.plugins.loaded.contains { $0.scope != .everything }
    }
}

private struct PluginSlots: View {
    let chain: PluginChain

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

                    Menu {
                        scopePicker(for: plugin)
                    } label: {
                        Image(systemName: plugin.scope.systemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(plugin.scope == .everything ? Color.secondary : Color.accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("적용 구간: \(plugin.scope.title)")

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
                    scopePicker(for: plugin)
                    Divider()
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

    private func scopePicker(for plugin: PluginChain.Loaded) -> some View {
        Picker("적용 구간", selection: Binding(get: { plugin.scope }, set: { chain.setScope($0, for: plugin) })) {
            ForEach(InsertScope.allCases, id: \.self) { scope in
                Label(scope.title, systemImage: scope.systemImage).tag(scope)
            }
        }
        .pickerStyle(.inline)
    }

    /// Apple's own effects last, after the plug-ins people install on purpose.
    private var orderedManufacturers: [String] {
        let all = chain.manufacturers
        return all.filter { $0 != "Apple" } + all.filter { $0 == "Apple" }
    }
}

/// Left and right output levels, peak and average, with the loudest moment held for a moment, and the loudness in
/// LUFS beneath: momentary and over the last three seconds. The scale runs past 0 dBFS to +6, as Logic Pro's does,
/// and is finer near the top, so how close the sound is to full scale is easy to read.
struct LevelMeter: View {
    let player: PreviewPlayer
    /// The loudness the export aims for, marked beside the readouts.
    let target: Double?

    var body: some View {
        let readouts = player.readouts
        VStack(spacing: 6) {
            Button {
                player.resetClip()
            } label: {
                let over = readouts.clipped || readouts.highest > 0
                Text(readouts.highest > -100 ? String(format: "%.1f", readouts.highest) : "–")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(over ? Color.white : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                    .background(over ? Color.red : Color.secondary.opacity(0.15), in: .rect(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("지금까지 가장 컸던 순간 (dBFS). 0을 넘으면 빨갛게 켜져요. 클릭하면 지워져요.")

            MeterBars(player: player)
                .frame(minHeight: 140, maxHeight: .infinity)
                .accessibilityLabel(Text("출력 레벨"))

            VStack(spacing: 2) {
                loudness("순간", readouts.momentary)
                loudness("3초", readouts.shortTerm)
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
}

private struct MeterBars: NSViewRepresentable {
    let player: PreviewPlayer

    func makeNSView(context: Context) -> MeterNSView {
        let view = MeterNSView()
        view.player = player
        return view
    }

    func updateNSView(_ view: MeterNSView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: MeterNSView, coordinator: ()) {
        view.player = nil
    }
}

/// The meter's bars, as Core Animation layers: each frame only moves a few rectangles. The scale is made once for
/// a size.
final class MeterNSView: NSView, PlaybackDisplay {
    weak var player: PreviewPlayer? {
        didSet {
            guard player !== oldValue else { return }
            oldValue?.removeDisplay(self)
            if window != nil { player?.addDisplay(self) }
        }
    }

    /// Evenly spaced up the meter, as on Logic Pro's: 3 dB apart near the top, wider apart further down.
    private static let marks: [Float] = [6, 3, 0, -3, -6, -9, -12, -15, -18, -21, -24, -30, -35, -40, -45, -50, -60]
    private static let lowest: Float = -60

    private struct Channel {
        let track = CALayer()
        let over = CALayer()
        let zones = CAGradientLayer()
        let reach = CALayer()
        let average = CALayer()
        let hold = CALayer()
    }

    private let channels = [Channel(), Channel()]
    private let scale = CALayer()
    private let zero = CALayer()
    private var bars: [CGRect] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for channel in channels {
            channel.track.cornerRadius = 2
            channel.over.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            channel.reach.backgroundColor = NSColor.black.cgColor
            channel.zones.mask = channel.reach
            channel.zones.opacity = 0.85
            channel.average.backgroundColor = NSColor(white: 1, alpha: 0.55).cgColor
            for layer in [channel.track, channel.over, channel.zones, channel.average, channel.hold] {
                self.layer?.addSublayer(layer)
            }
        }
        self.layer?.addSublayer(zero)
        self.layer?.addSublayer(scale)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var isShowing: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor && bounds.height > 0
    }

    var showsSpectrum: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { player?.addDisplay(self) } else { player?.removeDisplay(self) }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// From 0 at the bottom to 1 at the top, straight between neighbouring marks.
    private static func position(of decibels: Float) -> CGFloat {
        let marks = Self.marks
        if decibels >= marks[0] { return 1 }
        if decibels <= Self.lowest { return 0 }
        let steps = CGFloat(marks.count - 1)
        for index in 0..<(marks.count - 1) where decibels >= marks[index + 1] {
            let upper = marks[index]
            let lower = marks[index + 1]
            let fraction = CGFloat((decibels - lower) / (upper - lower))
            return 1 - (CGFloat(index) + 1 - fraction) / steps
        }
        return 0
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var colors: (primary: CGColor, secondary: CGColor, track: CGColor) = (NSColor.labelColor.cgColor, NSColor.secondaryLabelColor.cgColor, NSColor.secondaryLabelColor.cgColor)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            colors = (NSColor.labelColor.cgColor, NSColor.secondaryLabelColor.cgColor, NSColor.secondaryLabelColor.withAlphaComponent(0.15).cgColor)
        }
        let size = bounds.size
        let scaleWidth: CGFloat = 22
        let gap: CGFloat = 4
        // Wider bars where the strip has room, up to the width of a desk meter.
        let barWidth = min(max((size.width - scaleWidth - gap) / 2 - 12, 10), 18)
        let left = (size.width - scaleWidth - barWidth * 2 - gap) / 2
        let barsLeft = left + scaleWidth
        let height = size.height
        let zeroY = Self.position(of: 0) * height
        bars = (0..<2).map { CGRect(x: barsLeft + CGFloat($0) * (barWidth + gap), y: 0, width: barWidth, height: height) }

        // Green, yellow over the last 6 dB, red past full scale, as hard bands up the bar.
        let six = NSNumber(value: Double(Self.position(of: -6)))
        let full = NSNumber(value: Double(Self.position(of: 0)))
        for (channel, bar) in zip(channels, bars) {
            channel.track.frame = bar
            channel.track.backgroundColor = colors.track
            channel.over.frame = CGRect(x: bar.minX, y: zeroY, width: bar.width, height: height - zeroY)
            channel.zones.frame = bar
            channel.zones.colors = [NSColor.systemGreen, .systemGreen, .systemYellow, .systemYellow, .systemRed, .systemRed].map(\.cgColor)
            channel.zones.locations = [0, six, six, full, full, 1]
            channel.zones.startPoint = CGPoint(x: 0.5, y: 0)
            channel.zones.endPoint = CGPoint(x: 0.5, y: 1)
            channel.hold.backgroundColor = colors.primary
        }
        zero.frame = CGRect(x: barsLeft - 1, y: zeroY - 0.5, width: barWidth * 2 + gap + 2, height: 1)
        zero.backgroundColor = NSColor.labelColor.withAlphaComponent(0.6).cgColor

        // The scale: every mark where there's room, every other one where there isn't.
        let spacing = height / CGFloat(Self.marks.count - 1)
        let contentsScale = window?.backingScaleFactor ?? 2
        scale.sublayers = Self.marks.enumerated().compactMap { index, mark in
            guard spacing >= 10 || index % 2 == 0 || mark == 0 else { return nil }
            let label = CATextLayer()
            label.string = mark > 0 ? "+\(Int(mark))" : "\(Int(mark))"
            label.font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: mark == 0 ? .bold : .regular)
            label.fontSize = 8
            label.foregroundColor = mark == 0 ? colors.primary : colors.secondary
            label.alignmentMode = .right
            label.contentsScale = contentsScale
            let y = min(max(Self.position(of: mark) * height, 5), height - 5)
            label.frame = CGRect(x: 0, y: y - 5.5, width: barsLeft - 4, height: 11)
            return label
        }
        refresh()
    }

    func refresh() {
        guard bars.count == 2 else { return }
        let reading = player?.meter ?? .silent
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, channel) in channels.enumerated() {
            let bar = bars[index]
            channel.reach.frame = CGRect(x: 0, y: 0, width: bar.width, height: Self.position(of: reading.peak[index]) * bar.height)
            let average = Self.position(of: reading.rms[index]) * bar.height
            channel.average.frame = CGRect(x: bar.minX + bar.width * 0.3, y: 0, width: bar.width * 0.4, height: average)
            if reading.hold[index] > Self.lowest {
                channel.hold.isHidden = false
                channel.hold.frame = CGRect(x: bar.minX, y: Self.position(of: reading.hold[index]) * bar.height - 1, width: bar.width, height: 2)
            } else {
                channel.hold.isHidden = true
            }
        }
    }
}
