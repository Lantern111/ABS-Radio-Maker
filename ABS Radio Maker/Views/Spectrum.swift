import SwiftUI

/// Draws the spectrum and the EQ curve, for the channel strip's small display and the EQ window's big one.
struct SpectrumDrawing {
    let levels: [Float]
    let binWidth: Double
    let settings: SpectrumSettings
    /// The spectrum's range, in dB after the tilt.
    var floor = -96.0
    var ceiling = -6.0

    static let background = Color(white: 0.075)
    static let lineColor = Color(red: 0.45, green: 0.82, blue: 1.0)
    static let curveColor = Color(red: 1.0, green: 0.78, blue: 0.3)

    /// The level between two places across the display, from 0 to 1, with the tilt added. Where bins are wider than
    /// the stretch, it's read between the nearest two; where they're narrower, the loudest one counts.
    func level(from start: Double, to end: Double) -> Double? {
        guard levels.count > 2, binWidth > 0 else { return nil }
        let low = settings.frequency(at: start) / binWidth
        let high = settings.frequency(at: end) / binWidth
        let last = levels.count - 1
        var value: Double
        if high - low < 1 {
            let bin = min(max((low + high) / 2, 1), Double(last))
            let index = min(Int(bin), last - 1)
            let fraction = bin - Double(index)
            value = Double(levels[index]) * (1 - fraction) + Double(levels[index + 1]) * fraction
        } else {
            let first = min(max(Int(low.rounded(.up)), 1), last)
            let final = min(max(Int(high), first), last)
            value = Double(levels[first])
            for index in first...final { value = max(value, Double(levels[index])) }
        }
        let center = settings.frequency(at: (start + end) / 2)
        value += settings.tilt * log2(center / 1000)
        return value
    }

    func draw(in context: inout GraphicsContext, rect: CGRect, compact: Bool) {
        guard levels.count > 2 else { return }
        if settings.style != .line { drawBars(in: &context, rect: rect, compact: compact) }
        if settings.style != .bars { drawLine(in: &context, rect: rect, filled: settings.style == .line) }
    }

    private func y(for decibels: Double, in rect: CGRect) -> CGFloat {
        let fraction = (decibels - floor) / (ceiling - floor)
        return rect.maxY - CGFloat(min(max(fraction, 0), 1)) * rect.height
    }

    private func drawLine(in context: inout GraphicsContext, rect: CGRect, filled: Bool) {
        let step: CGFloat = 2
        var line = Path()
        var x = rect.minX
        var started = false
        while x <= rect.maxX {
            let start = Double((x - rect.minX) / rect.width)
            let end = Double((x + step - rect.minX) / rect.width)
            guard let value = level(from: start, to: min(end, 1)) else { return }
            let point = CGPoint(x: x, y: y(for: value, in: rect))
            if started { line.addLine(to: point) } else { line.move(to: point); started = true }
            x += step
        }
        if filled {
            var area = line
            area.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            area.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(
                Gradient(colors: [Self.lineColor.opacity(0.35), Self.lineColor.opacity(0.04)]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            ))
        }
        context.stroke(line, with: .color(filled ? Self.lineColor : .white.opacity(0.9)), lineWidth: 1.2)
    }

    private func drawBars(in context: inout GraphicsContext, rect: CGRect, compact: Bool) {
        let count = compact ? 28 : max(24, Int(rect.width / 10))
        let width = rect.width / CGFloat(count)
        let gap = max(1, width * 0.18)
        for index in 0..<count {
            let start = Double(index) / Double(count)
            let end = Double(index + 1) / Double(count)
            guard let value = level(from: start, to: end) else { return }
            let top = y(for: value, in: rect)
            guard top < rect.maxY - 0.5 else { continue }
            let bar = CGRect(x: rect.minX + CGFloat(index) * width + gap / 2, y: top, width: width - gap, height: rect.maxY - top)
            // Red at the bottom of the range through to violet at the top, like MiniMeters' colour bars.
            let hue = 0.0 + 0.78 * (start + end) / 2
            context.fill(
                Path(roundedRect: bar, cornerSize: CGSize(width: 1.5, height: 1.5)),
                with: .color(Color(hue: hue, saturation: 0.72, brightness: 0.95).opacity(settings.style == .both ? 0.75 : 0.9))
            )
        }
    }

    // MARK: - Grid and EQ curve

    static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    static let labelFrequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 3_000, 5_000, 7_000, 10_000, 15_000, 20_000]

    static func label(for frequency: Double) -> String {
        frequency >= 1000 ? "\(frequency.truncatingRemainder(dividingBy: 1000) == 0 ? String(Int(frequency / 1000)) : String(format: "%.1f", frequency / 1000))k" : "\(Int(frequency))"
    }

    /// Lines at round frequencies, labelled along the bottom where they don't crowd each other.
    func drawFrequencyGrid(in context: inout GraphicsContext, rect: CGRect, labels: Bool) {
        for frequency in Self.gridFrequencies {
            let x = rect.minX + CGFloat(settings.position(of: frequency)) * rect.width
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: rect.minY)); $0.addLine(to: CGPoint(x: x, y: rect.maxY)) },
                           with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
        guard labels else { return }
        var lastX = -CGFloat.infinity
        for frequency in Self.labelFrequencies {
            let x = rect.minX + CGFloat(settings.position(of: frequency)) * rect.width
            guard x - lastX > 30 else { continue }
            lastX = x
            let text = context.resolve(Text(Self.label(for: frequency)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.45)))
            context.draw(text, at: CGPoint(x: min(max(x, rect.minX + 8), rect.maxX - 10), y: rect.maxY - 7))
        }
    }

    /// The EQ's effect across the display, with `range` dB above and below the middle.
    func curve(_ equalizer: EQSettings, in rect: CGRect, range: Double, sampleRate: Double) -> Path {
        var path = Path()
        var x = rect.minX
        while x <= rect.maxX + 0.5 {
            let frequency = settings.frequency(at: Double((x - rect.minX) / rect.width))
            let decibels = equalizer.response(at: frequency, sampleRate: sampleRate)
            let point = CGPoint(x: x, y: Self.y(forGain: decibels, in: rect, range: range))
            if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
            x += 1.5
        }
        return path
    }

    static func y(forGain decibels: Double, in rect: CGRect, range: Double) -> CGFloat {
        let fraction = min(max(decibels / range, -1.05), 1.05)
        return rect.midY - CGFloat(fraction) * rect.height / 2
    }

    static func gain(atY y: CGFloat, in rect: CGRect, range: Double) -> Double {
        Double((rect.midY - y) / (rect.height / 2)) * range
    }
}

/// Keeps the analyzer working while a view shows it.
struct WatchesSpectrum: ViewModifier {
    let analyzer: SpectrumAnalyzer

    func body(content: Content) -> some View {
        content
            .onAppear { analyzer.watchers += 1 }
            .onDisappear { analyzer.watchers = max(analyzer.watchers - 1, 0) }
    }
}

/// The spectrum's settings, shown in place of the spectrum, as MiniMeters does.
struct SpectrumSettingsPanel: View {
    @Binding var settings: SpectrumSettings
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("스펙트럼 설정")
                    .font(.headline)
                Spacer()
                Button("기본값") { settings = SpectrumSettings() }
                    .controlSize(.small)
                Button("완료", action: done)
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                row("Style", detail: "선 / 색 막대 / 둘 다") {
                    Picker("Style", selection: $settings.style) {
                        ForEach(SpectrumSettings.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                row("Smoothing", detail: "높을수록 천천히 움직여요") {
                    HStack {
                        Slider(value: $settings.smoothing, in: SpectrumSettings.smoothingRange)
                        Text(String(format: "%.2f", settings.smoothing))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                row("Tilt", detail: "높은 음을 올려서 보여줘요 (1 kHz 기준)") {
                    HStack {
                        Slider(value: $settings.tilt, in: SpectrumSettings.tiltRange, step: 0.5)
                        Text(String(format: "%.1f dB/oct", settings.tilt))
                            .monospacedDigit()
                            .frame(width: 76, alignment: .trailing)
                    }
                }
                row("FFT Size", detail: "클수록 낮은 음이 자세하고, 작을수록 빨라요") {
                    Picker("FFT Size", selection: $settings.fftSize) {
                        ForEach(SpectrumSettings.fftSizes, id: \.self) { Text(String($0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                row("FFT Scale", detail: "주파수를 늘어놓는 방법") {
                    Picker("FFT Scale", selection: $settings.scale) {
                        ForEach(SpectrumSettings.Scale.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ title: String, detail: String, @ViewBuilder control: () -> some View) -> some View {
        GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)
            control()
                .frame(maxWidth: 420)
        }
    }
}
