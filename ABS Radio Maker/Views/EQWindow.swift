import AppKit
import SwiftUI

/// The channel EQ, laid out like Logic Pro's Channel EQ: the spectrum of what's playing with the EQ curve over it, a
/// point for each band to drag, and the bands' numbers along the bottom. ⚙︎ swaps the spectrum for its settings.
struct EQWindow: View {
    @Bindable var studio: Studio
    @State private var selected: Int?
    @State private var showsSettings = false

    static let bandColors: [Color] = [
        Color(red: 1.0, green: 0.36, blue: 0.36),
        Color(red: 1.0, green: 0.6, blue: 0.25),
        Color(red: 0.98, green: 0.85, blue: 0.3),
        Color(red: 0.45, green: 0.85, blue: 0.4),
        Color(red: 0.3, green: 0.85, blue: 0.8),
        Color(red: 0.35, green: 0.6, blue: 1.0),
        Color(red: 0.66, green: 0.48, blue: 1.0),
        Color(red: 1.0, green: 0.45, blue: 0.75),
    ]

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
                    EQGraph(studio: studio, selected: $selected)
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

/// One band's switch and numbers.
private struct BandColumn: View {
    let band: EQBand
    let color: Color
    let isSelected: Bool
    let set: (EQBand) -> Void
    let select: () -> Void

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

/// The big display: grid, spectrum, curve, and band points. Points are dragged with the mouse; the scroll wheel over
/// the display changes the Q of the band under the pointer, or the selected one.
private struct EQGraph: View {
    let studio: Studio
    @Binding var selected: Int?
    @State private var drag: (band: Int?, offset: CGSize)?
    @State private var hovering: CGPoint?
    @State private var lastClick: (band: Int, time: Date)?
    @State private var pointer = Pointer()

    static let range = 24.0
    private static let insets = EdgeInsets(top: 12, leading: 36, bottom: 20, trailing: 12)

    /// What the scroll wheel needs to know, kept outside the view so the event monitor always reads the latest.
    @MainActor final class Pointer {
        var location: CGPoint?
        var plot = CGRect.zero
        var target: () -> Int? = { nil }
        /// A plain view behind the display, to place scroll events in the display's own coordinates.
        weak var anchor: NSView?
        private var monitor: Any?

        func install(_ handler: @escaping (CGFloat) -> Void) {
            remove()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let anchor = self.anchor, event.window === anchor.window else { return false }
                    let location = anchor.convert(event.locationInWindow, from: nil)
                    guard self.plot.insetBy(dx: -20, dy: -20).contains(location) else { return false }
                    self.location = location
                    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                    handler(delta)
                    return true
                }
                return handled ? nil : event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    var body: some View {
        let analyzer = studio.player.spectrum
        let drawing = SpectrumDrawing(levels: analyzer.levels, binWidth: analyzer.binWidth, settings: studio.spectrumSettings)
        let equalizer = studio.equalizer
        let sampleRate = studio.player.sampleRate
        let hovered = hovering
        let selectedBand = selected

        GeometryReader { geometry in
            let plot = Self.plot(in: geometry.size)
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SpectrumDrawing.background))
                drawing.drawFrequencyGrid(in: &context, rect: plot, labels: true)
                Self.drawGainGrid(in: &context, rect: plot)
                drawing.draw(in: &context, rect: plot, compact: false)

                // The selected band's own shape, faintly.
                if let selectedBand, equalizer.bands.indices.contains(selectedBand), equalizer.bands[selectedBand].isOn {
                    var single = equalizer
                    single.bands = equalizer.bands.map { band in
                        var band = band
                        band.isOn = band.id == selectedBand
                        return band
                    }
                    single.isOn = true
                    context.stroke(drawing.curve(single, in: plot, range: Self.range, sampleRate: sampleRate),
                                   with: .color(EQWindow.bandColors[selectedBand].opacity(0.55)), lineWidth: 1)
                }

                // The whole EQ.
                let curve = drawing.curve(equalizer, in: plot, range: Self.range, sampleRate: sampleRate)
                var area = curve
                area.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
                area.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
                area.closeSubpath()
                if equalizer.isOn {
                    context.fill(area, with: .color(SpectrumDrawing.curveColor.opacity(0.13)))
                    context.stroke(curve, with: .color(SpectrumDrawing.curveColor), lineWidth: 2)
                } else {
                    context.stroke(curve, with: .color(.gray.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }

                // Band points.
                let near = hovered.flatMap { Self.nearestBand(to: $0, equalizer: equalizer, drawing: drawing, plot: plot, sampleRate: sampleRate, within: 16) }
                for band in equalizer.bands {
                    let center = Self.point(of: band, drawing: drawing, plot: plot, sampleRate: sampleRate)
                    let color = EQWindow.bandColors[band.id % EQWindow.bandColors.count]
                    let radius: CGFloat = band.id == selectedBand || band.id == near ? 7.5 : 6
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    if band.isOn && equalizer.isOn {
                        context.fill(circle, with: .color(color))
                    } else {
                        context.fill(circle, with: .color(SpectrumDrawing.background))
                        context.stroke(circle, with: .color(color.opacity(0.7)), lineWidth: 1.5)
                    }
                    if band.id == selectedBand {
                        context.stroke(circle, with: .color(.white), lineWidth: 1.5)
                    }
                    let number = context.resolve(Text("\(band.id + 1)").font(.system(size: 8, weight: .bold)).foregroundStyle(band.isOn && equalizer.isOn ? Color.black.opacity(0.75) : color))
                    context.draw(number, at: center)
                }

                // What the selected band is set to.
                if let selectedBand, equalizer.bands.indices.contains(selectedBand) {
                    let band = equalizer.bands[selectedBand]
                    var parts = ["\(selectedBand + 1). \(band.kind.title)", Self.frequencyText(band.frequency)]
                    if band.kind.hasGain { parts.append(String(format: "%+.1f dB", band.gain)) }
                    parts.append(String(format: "Q %.2f", band.q))
                    if !band.isOn { parts.append("꺼짐") }
                    let text = context.resolve(Text(parts.joined(separator: "   "))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(EQWindow.bandColors[selectedBand]))
                    context.draw(text, at: CGPoint(x: plot.minX + 8, y: plot.minY + 10), anchor: .leading)
                }
            }
            .background(ScrollAnchor(pointer: pointer))
            .contentShape(Rectangle())
            .gesture(dragGesture(drawing: drawing, plot: plot, sampleRate: sampleRate))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hovering = location
                    pointer.location = location
                case .ended:
                    hovering = nil
                    pointer.location = nil
                }
            }
            .onAppear { pointer.plot = plot }
            .onChange(of: geometry.size) { pointer.plot = Self.plot(in: geometry.size) }
        }
        .modifier(WatchesSpectrum(analyzer: analyzer))
        .onAppear {
            pointer.target = {
                let equalizer = studio.equalizer
                let drawing = SpectrumDrawing(levels: [], binWidth: 0, settings: studio.spectrumSettings)
                if let location = pointer.location,
                   let near = Self.nearestBand(to: location, equalizer: equalizer, drawing: drawing, plot: pointer.plot, sampleRate: studio.player.sampleRate, within: 40) {
                    return near
                }
                return selected
            }
            pointer.install { delta in
                guard let id = pointer.target() else { return }
                var band = studio.equalizer.bands[id]
                band.q *= exp(Double(delta) * 0.012)
                band.q = (band.q * 100).rounded() / 100
                studio.setBand(band)
                selected = id
            }
        }
        .onDisappear { pointer.remove() }
    }

    private func dragGesture(drawing: SpectrumDrawing, plot: CGRect, sampleRate: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    let equalizer = studio.equalizer
                    if let id = Self.nearestBand(to: value.startLocation, equalizer: equalizer, drawing: drawing, plot: plot, sampleRate: sampleRate, within: 14) {
                        let center = Self.point(of: equalizer.bands[id], drawing: drawing, plot: plot, sampleRate: sampleRate)
                        drag = (id, CGSize(width: center.x - value.startLocation.x, height: center.y - value.startLocation.y))
                        selected = id
                    } else {
                        drag = (nil, .zero)
                    }
                }
                guard let drag, let id = drag.band, hypot(value.translation.width, value.translation.height) >= 1 else { return }
                let target = CGPoint(x: value.location.x + drag.offset.width, y: value.location.y + drag.offset.height)
                var band = studio.equalizer.bands[id]
                band.frequency = Self.rounded(drawing.settings.frequency(at: Double((target.x - plot.minX) / plot.width)))
                if band.kind.hasGain {
                    let gain = SpectrumDrawing.gain(atY: target.y, in: plot, range: Self.range)
                    // A little stickiness at 0 dB, so a band can be put back flat.
                    band.gain = abs(gain) < 0.3 ? 0 : (gain * 10).rounded() / 10
                }
                band.isOn = true
                studio.setBand(band)
            }
            .onEnded { value in
                defer { drag = nil }
                guard let current = drag else { return }
                guard let id = current.band else {
                    selected = nil
                    return
                }
                guard hypot(value.translation.width, value.translation.height) < 3 else { return }
                // A second click on the same point soon after switches the band.
                if let last = lastClick, last.band == id, Date().timeIntervalSince(last.time) < 0.4 {
                    var band = studio.equalizer.bands[id]
                    band.isOn.toggle()
                    studio.setBand(band)
                    lastClick = nil
                } else {
                    lastClick = (id, Date())
                }
            }
    }

    static func plot(in size: CGSize) -> CGRect {
        CGRect(
            x: insets.leading,
            y: insets.top,
            width: max(size.width - insets.leading - insets.trailing, 10),
            height: max(size.height - insets.top - insets.bottom, 10)
        )
    }

    /// Where a band's point sits: at its frequency and gain, or on the curve for the cuts, which have no gain.
    static func point(of band: EQBand, drawing: SpectrumDrawing, plot: CGRect, sampleRate: Double) -> CGPoint {
        let x = plot.minX + CGFloat(drawing.settings.position(of: band.frequency)) * plot.width
        var shape = band
        shape.isOn = true
        let gain = band.kind.hasGain ? band.gain : shape.response(at: band.frequency, sampleRate: sampleRate)
        return CGPoint(x: x, y: SpectrumDrawing.y(forGain: gain, in: plot, range: range))
    }

    static func nearestBand(to location: CGPoint, equalizer: EQSettings, drawing: SpectrumDrawing, plot: CGRect, sampleRate: Double, within distance: CGFloat) -> Int? {
        var best: (id: Int, distance: CGFloat)?
        for band in equalizer.bands {
            let center = point(of: band, drawing: drawing, plot: plot, sampleRate: sampleRate)
            let away = hypot(center.x - location.x, center.y - location.y)
            if away <= distance, away < (best?.distance ?? .infinity) { best = (band.id, away) }
        }
        return best?.id
    }

    static func rounded(_ frequency: Double) -> Double {
        frequency < 100 ? (frequency * 2).rounded() / 2 : frequency < 1000 ? frequency.rounded() : (frequency / 10).rounded() * 10
    }

    static func frequencyText(_ frequency: Double) -> String {
        frequency >= 1000 ? String(format: "%.2f kHz", frequency / 1000) : String(format: "%.0f Hz", frequency)
    }

    static func drawGainGrid(in context: inout GraphicsContext, rect: CGRect) {
        for gain in stride(from: -range, through: range, by: 6) {
            let y = SpectrumDrawing.y(forGain: gain, in: rect, range: range)
            context.stroke(Path { $0.move(to: CGPoint(x: rect.minX, y: y)); $0.addLine(to: CGPoint(x: rect.maxX, y: y)) },
                           with: .color(.white.opacity(gain == 0 ? 0.22 : 0.06)), lineWidth: 1)
            guard Int(gain) % 12 == 0 else { continue }
            let label = context.resolve(Text(gain == 0 ? "0" : String(format: "%+.0f", gain))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45)))
            context.draw(label, at: CGPoint(x: rect.minX - 6, y: y), anchor: .trailing)
        }
    }
}

/// Hands the EQ display's scroll handling a view in the same place, flipped like SwiftUI's coordinates.
private struct ScrollAnchor: NSViewRepresentable {
    let pointer: EQGraph.Pointer

    final class Anchor: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Anchor {
        let view = Anchor()
        pointer.anchor = view
        return view
    }

    func updateNSView(_ view: Anchor, context: Context) {
        pointer.anchor = view
    }
}

/// The small EQ display at the top of the channel strip: what's playing, and the EQ's curve. Clicking opens the window.
struct EQThumbnail: View {
    let studio: Studio
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let analyzer = studio.player.spectrum
        // The small display always draws a line; bars at this size are too busy.
        let settings = { var settings = studio.spectrumSettings; settings.style = .line; return settings }()
        let drawing = SpectrumDrawing(levels: analyzer.levels, binWidth: analyzer.binWidth, settings: settings)
        let equalizer = studio.equalizer
        let sampleRate = studio.player.sampleRate

        Button {
            openWindow(id: "eq")
        } label: {
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(SpectrumDrawing.background))
                drawing.drawFrequencyGrid(in: &context, rect: rect, labels: false)
                let zero = SpectrumDrawing.y(forGain: 0, in: rect, range: 18)
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: zero)); $0.addLine(to: CGPoint(x: size.width, y: zero)) },
                               with: .color(.white.opacity(0.12)), lineWidth: 1)
                drawing.draw(in: &context, rect: rect, compact: true)
                let curve = drawing.curve(equalizer, in: rect, range: 18, sampleRate: sampleRate)
                if equalizer.isOn {
                    context.stroke(curve, with: .color(SpectrumDrawing.curveColor), lineWidth: 1.5)
                } else {
                    context.stroke(curve, with: .color(.gray.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
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
                        .foregroundStyle(SpectrumDrawing.curveColor)
                        .padding(4)
                }
            }
            .clipShape(.rect(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("채널 EQ 열기 (⌥⌘E)")
        .modifier(WatchesSpectrum(analyzer: analyzer))
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
