import AppKit
import SwiftUI

/// The spectrum of what's playing with the EQ curve over it: the channel strip's small display, and with `editsBands`
/// the EQ window's big one, with a point to drag for each band.
///
/// Drawn with Core Animation layers, so following the sound costs little: each frame only the spectrum's line and bars
/// get new shapes, which the system draws. The grid and labels are made once for a size, and the curve and points only
/// when the EQ changes. The player refreshes it while it's visible and leaves it alone when it isn't.
final class SpectrumNSView: NSView, PlaybackDisplay {
    let editsBands: Bool
    weak var player: PreviewPlayer? {
        didSet {
            oldValue?.removeDisplay(self)
            if window != nil { player?.addDisplay(self) }
        }
    }
    var settings = SpectrumSettings() {
        didSet {
            guard settings != oldValue else { return }
            columnsKey = nil
            needsLayout = true
            refresh()
        }
    }
    var equalizer = EQSettings() {
        didSet {
            guard equalizer != oldValue else { return }
            updateCurve()
            updateHandles()
        }
    }
    var selected: Int? {
        didSet {
            guard selected != oldValue else { return }
            updateCurve()
            updateHandles()
        }
    }
    var sampleRate = 44_100.0 {
        didSet {
            guard sampleRate != oldValue else { return }
            updateCurve()
            updateHandles()
        }
    }
    var onChange: (EQBand) -> Void = { _ in }
    var onSelect: (Int?) -> Void = { _ in }

    static let background = NSColor(white: 0.075, alpha: 1)
    static let lineColor = NSColor(red: 0.45, green: 0.82, blue: 1.0, alpha: 1)
    static let curveColor = NSColor(red: 1.0, green: 0.78, blue: 0.3, alpha: 1)
    static let bandColors: [NSColor] = [
        NSColor(red: 1.0, green: 0.36, blue: 0.36, alpha: 1),
        NSColor(red: 1.0, green: 0.6, blue: 0.25, alpha: 1),
        NSColor(red: 0.98, green: 0.85, blue: 0.3, alpha: 1),
        NSColor(red: 0.45, green: 0.85, blue: 0.4, alpha: 1),
        NSColor(red: 0.3, green: 0.85, blue: 0.8, alpha: 1),
        NSColor(red: 0.35, green: 0.6, blue: 1.0, alpha: 1),
        NSColor(red: 0.66, green: 0.48, blue: 1.0, alpha: 1),
        NSColor(red: 1.0, green: 0.45, blue: 0.75, alpha: 1),
    ]
    /// The spectrum's range, in dB after the tilt.
    private static let floor: Float = -96
    private static let ceiling: Float = -6

    private var gainRange: Double { editsBands ? 24 : 18 }

    private let gridLayer = CAShapeLayer()
    private let zeroLayer = CAShapeLayer()
    private let labelsLayer = CALayer()
    /// Plain layers, no masks: a mask makes the window server draw the layer twice every frame.
    private let barsLayer = CALayer()
    private var bars: [CALayer] = []
    private let fillLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private let curveFill = CAShapeLayer()
    private let curveLayer = CAShapeLayer()
    private let singleCurve = CAShapeLayer()
    private var handles: [CAShapeLayer] = []
    private var numbers: [CATextLayer] = []
    private let readout = CATextLayer()

    /// Which bins each column and bar reads, worked out once for a size, scale, and FFT size.
    private struct Column {
        /// With `last` below 0, read between `first` and the next bin, `fraction` of the way.
        var first: Int
        var last: Int
        var fraction: Float
        var tilt: Float
    }
    private var lineColumns: [Column] = []
    private var barColumns: [Column] = []
    private var columnsKey: [Double]?

    /// The curve's frequencies, one every step across, and each band's effect at them. A change to one band only
    /// works out that band again.
    private var curveFrequencies: [Double] = []
    private var curveKey: [Double] = []
    private var bandShapes: [(band: EQBand, responses: [Double])?] = []

    private var dragging: (band: Int, offset: CGSize)?
    private var hovered: Int?

    init(editsBands: Bool) {
        self.editsBands = editsBands
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Self.background.cgColor
        layer?.masksToBounds = true
        if !editsBands { layer?.cornerRadius = 5 }

        gridLayer.strokeColor = NSColor(white: 1, alpha: 0.07).cgColor
        gridLayer.lineWidth = 1
        zeroLayer.strokeColor = NSColor(white: 1, alpha: editsBands ? 0.22 : 0.12).cgColor
        zeroLayer.lineWidth = 1

        fillLayer.fillColor = Self.lineColor.withAlphaComponent(0.16).cgColor
        fillLayer.strokeColor = nil

        lineLayer.fillColor = nil
        lineLayer.lineWidth = 1.2
        lineLayer.lineJoin = .round

        curveFill.fillColor = Self.curveColor.withAlphaComponent(0.13).cgColor
        curveLayer.fillColor = nil
        curveLayer.lineJoin = .round
        singleCurve.fillColor = nil
        singleCurve.lineWidth = 1

        for layer in [gridLayer, zeroLayer, labelsLayer, barsLayer, fillLayer, lineLayer, curveFill, singleCurve, curveLayer] {
            self.layer?.addSublayer(layer)
        }
        if editsBands {
            for index in EQSettings.standardBands.indices {
                let handle = CAShapeLayer()
                handle.path = CGPath(ellipseIn: CGRect(x: -6, y: -6, width: 12, height: 12), transform: nil)
                handle.lineWidth = 1.5
                let number = CATextLayer()
                number.string = "\(index + 1)"
                number.font = NSFont.systemFont(ofSize: 8, weight: .bold)
                number.fontSize = 8
                number.alignmentMode = .center
                number.bounds = CGRect(x: 0, y: 0, width: 12, height: 10)
                self.layer?.addSublayer(handle)
                self.layer?.addSublayer(number)
                handles.append(handle)
                numbers.append(number)
            }
            readout.fontSize = 11
            readout.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            readout.alignmentMode = .left
            self.layer?.addSublayer(readout)
        }
        updateScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Showing

    var isShowing: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor && bounds.width > 0
    }

    var showsSpectrum: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            player?.addDisplay(self)
            updateScale()
        } else {
            player?.removeDisplay(self)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        let scale = window?.backingScaleFactor ?? 2
        for layer in [readout] + numbers { layer.contentsScale = scale }
        labelsLayer.sublayers?.forEach { $0.contentsScale = scale }
    }

    /// Where the spectrum and curve are drawn. The big display keeps room for labels on the left and bottom.
    private var plot: CGRect {
        guard editsBands else { return bounds }
        return CGRect(x: 36, y: 20, width: max(bounds.width - 48, 10), height: max(bounds.height - 32, 10))
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        barsLayer.frame = plot
        drawGrid()
        updateCurve()
        updateHandles()
        CATransaction.commit()
        refresh()
    }

    // MARK: - Spectrum, every frame

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let levels = player?.spectrum.levels ?? []
        let binWidth = player?.spectrum.binWidth ?? 0
        let plot = plot
        guard levels.count > 2, binWidth > 0, plot.width > 4 else {
            lineLayer.path = nil
            fillLayer.path = nil
            bars.forEach { $0.isHidden = true }
            return
        }
        let key = [Double(plot.width), Double(levels.count), binWidth, settings.tilt, Double(SpectrumSettings.Scale.allCases.firstIndex(of: settings.scale) ?? 0)]
        if key != columnsKey {
            lineColumns = makeColumns(count: max(Int(plot.width / 2), 2), binWidth: binWidth, binCount: levels.count)
            barColumns = makeColumns(count: editsBands ? max(24, Int(plot.width / 10)) : 28, binWidth: binWidth, binCount: levels.count)
            columnsKey = key
            makeBars()
        }

        let showsBars = settings.style != .line
        let showsLine = settings.style != .bars
        let filled = settings.style == .line
        barsLayer.isHidden = !showsBars
        fillLayer.isHidden = !filled
        lineLayer.isHidden = !showsLine
        lineLayer.strokeColor = filled ? Self.lineColor.cgColor : NSColor(white: 1, alpha: 0.9).cgColor
        barsLayer.opacity = settings.style == .both ? 0.8 : 0.95

        levels.withUnsafeBufferPointer { levels in
            if showsLine {
                let line = CGMutablePath()
                let step = plot.width / CGFloat(lineColumns.count - 1)
                for (index, column) in lineColumns.enumerated() {
                    let point = CGPoint(x: plot.minX + CGFloat(index) * step, y: height(of: value(column, levels), in: plot))
                    if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                lineLayer.path = line
                if filled {
                    let area = CGMutablePath()
                    area.addPath(line)
                    area.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
                    area.addLine(to: CGPoint(x: plot.minX, y: plot.minY))
                    area.closeSubpath()
                    fillLayer.path = area
                }
            }
            if showsBars {
                let width = plot.width / CGFloat(barColumns.count)
                let gap = max(1, width * 0.18)
                for (index, column) in barColumns.enumerated() where index < bars.count {
                    let top = height(of: value(column, levels), in: plot) - plot.minY
                    bars[index].isHidden = top <= 0.5
                    bars[index].frame = CGRect(x: CGFloat(index) * width + gap / 2, y: 0, width: width - gap, height: max(top, 0))
                }
            }
        }
    }

    /// One plain layer per bar, red at the low end through to violet at the top, like MiniMeters' colour bars.
    private func makeBars() {
        bars = barColumns.indices.map { index in
            let bar = CALayer()
            let hue = 0.78 * (Double(index) + 0.5) / Double(barColumns.count)
            bar.backgroundColor = NSColor(hue: hue, saturation: 0.72, brightness: 0.95, alpha: 1).cgColor
            bar.cornerRadius = 1.5
            return bar
        }
        barsLayer.sublayers = bars
    }

    private func value(_ column: Column, _ levels: UnsafeBufferPointer<Float>) -> Float {
        var level: Float
        if column.last < 0 {
            let low = levels[column.first]
            level = low + (levels[column.first + 1] - low) * column.fraction
        } else {
            level = levels[column.first]
            if column.last > column.first {
                for index in (column.first + 1)...column.last { level = max(level, levels[index]) }
            }
        }
        return level + column.tilt
    }

    private func height(of decibels: Float, in plot: CGRect) -> CGFloat {
        let fraction = (decibels - Self.floor) / (Self.ceiling - Self.floor)
        return plot.minY + CGFloat(min(max(fraction, 0), 1)) * plot.height
    }

    /// Where bins are wider than a column, it reads between the nearest two; where they're narrower, the loudest
    /// bin in the column counts. The tilt is added per column.
    private func makeColumns(count: Int, binWidth: Double, binCount: Int) -> [Column] {
        let last = binCount - 1
        return (0..<count).map { index in
            let start = Double(index) / Double(count)
            let end = Double(index + 1) / Double(count)
            let low = settings.frequency(at: start) / binWidth
            let high = settings.frequency(at: end) / binWidth
            let tilt = Float(settings.tilt * log2(settings.frequency(at: (start + end) / 2) / 1000))
            if high - low < 1 {
                let bin = min(max((low + high) / 2, 1), Double(last))
                let first = min(Int(bin), last - 1)
                return Column(first: first, last: -1, fraction: Float(bin - Double(first)), tilt: tilt)
            }
            let first = min(max(Int(low.rounded(.up)), 1), last)
            return Column(first: first, last: min(max(Int(high), first), last), fraction: 0, tilt: tilt)
        }
    }

    // MARK: - Grid, made once for a size

    private static let gridFrequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private static let labelFrequencies: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 3_000, 5_000, 7_000, 10_000, 15_000, 20_000]

    private func x(of frequency: Double, in plot: CGRect) -> CGFloat {
        plot.minX + CGFloat(settings.position(of: frequency)) * plot.width
    }

    private func y(forGain decibels: Double, in plot: CGRect) -> CGFloat {
        plot.midY + CGFloat(min(max(decibels / gainRange, -1.05), 1.05)) * plot.height / 2
    }

    private func drawGrid() {
        let plot = plot
        let grid = CGMutablePath()
        for frequency in Self.gridFrequencies {
            let x = x(of: frequency, in: plot)
            grid.move(to: CGPoint(x: x, y: plot.minY))
            grid.addLine(to: CGPoint(x: x, y: plot.maxY))
        }
        var labels: [CATextLayer] = []
        if editsBands {
            for gain in stride(from: -gainRange, through: gainRange, by: 6) where gain != 0 {
                let y = y(forGain: gain, in: plot)
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            for gain in stride(from: -gainRange, through: gainRange, by: 12) {
                let label = textLayer(gain == 0 ? "0" : String(format: "%+.0f", gain), alignment: .right)
                label.frame = CGRect(x: 0, y: y(forGain: gain, in: plot) - 6, width: plot.minX - 6, height: 12)
                labels.append(label)
            }
            var lastX = -CGFloat.infinity
            for frequency in Self.labelFrequencies {
                let x = x(of: frequency, in: plot)
                guard x - lastX > 30 else { continue }
                lastX = x
                let label = textLayer(Self.label(for: frequency), alignment: .center)
                label.frame = CGRect(x: min(max(x - 16, plot.minX), plot.maxX - 32), y: plot.minY - 16, width: 32, height: 12)
                labels.append(label)
            }
        }
        gridLayer.path = grid
        let zero = CGMutablePath()
        let zeroY = y(forGain: 0, in: plot)
        zero.move(to: CGPoint(x: plot.minX, y: zeroY))
        zero.addLine(to: CGPoint(x: plot.maxX, y: zeroY))
        zeroLayer.path = zero
        labelsLayer.sublayers = labels
        updateScale()
    }

    private func textLayer(_ text: String, alignment: CATextLayerAlignmentMode) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = text
        layer.font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        layer.fontSize = 9
        layer.foregroundColor = NSColor(white: 1, alpha: 0.45).cgColor
        layer.alignmentMode = alignment
        return layer
    }

    static func label(for frequency: Double) -> String {
        guard frequency >= 1000 else { return "\(Int(frequency))" }
        let thousands = frequency / 1000
        return thousands.rounded() == thousands ? "\(Int(thousands))k" : String(format: "%.1fk", thousands)
    }

    // MARK: - EQ curve and points, when the EQ changes

    private func curvePath(_ gains: [Double], in plot: CGRect) -> CGMutablePath {
        let path = CGMutablePath()
        guard gains.count > 1 else { return path }
        let step = plot.width / CGFloat(gains.count - 1)
        for (index, gain) in gains.enumerated() {
            let point = CGPoint(x: plot.minX + CGFloat(index) * step, y: y(forGain: gain, in: plot))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Each band's effect along the curve, worked out again only for bands that changed.
    private func bandResponses(in plot: CGRect) -> [[Double]] {
        let key = [Double(plot.width), sampleRate, Double(SpectrumSettings.Scale.allCases.firstIndex(of: settings.scale) ?? 0)]
        if key != curveKey {
            let count = max(Int(plot.width / (editsBands ? 1.5 : 2)), 2)
            curveFrequencies = (0..<count).map { settings.frequency(at: Double($0) / Double(count - 1)) }
            bandShapes = []
            curveKey = key
        }
        if bandShapes.count != equalizer.bands.count {
            bandShapes = Array(repeating: nil, count: equalizer.bands.count)
        }
        return equalizer.bands.enumerated().map { index, band in
            if let shape = bandShapes[index], shape.band == band { return shape.responses }
            let responses = band.responses(at: curveFrequencies, sampleRate: sampleRate)
            bandShapes[index] = (band, responses)
            return responses
        }
    }

    private func updateCurve() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let plot = plot
        guard plot.width > 4 else { return }
        let responses = bandResponses(in: plot)
        var total = [Double](repeating: 0, count: curveFrequencies.count)
        if equalizer.isOn {
            for band in responses {
                for index in total.indices { total[index] += band[index] }
            }
        }
        let curve = curvePath(total, in: plot)
        curveLayer.path = curve
        if equalizer.isOn {
            curveLayer.strokeColor = Self.curveColor.cgColor
            curveLayer.lineWidth = editsBands ? 2 : 1.5
            curveLayer.lineDashPattern = nil
        } else {
            curveLayer.strokeColor = NSColor(white: 0.55, alpha: 0.7).cgColor
            curveLayer.lineWidth = 1.5
            curveLayer.lineDashPattern = [5, 4]
        }
        if editsBands, equalizer.isOn {
            let area = CGMutablePath()
            area.addPath(curve)
            area.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
            area.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
            area.closeSubpath()
            curveFill.path = area
        } else {
            curveFill.path = nil
        }
        // The selected band's own shape, faintly.
        if editsBands, let selected, responses.indices.contains(selected), equalizer.bands[selected].isOn {
            singleCurve.path = curvePath(responses[selected], in: plot)
            singleCurve.strokeColor = Self.bandColors[selected % Self.bandColors.count].withAlphaComponent(0.55).cgColor
        } else {
            singleCurve.path = nil
        }
    }

    /// Where a band's point sits: at its frequency and gain, or on its own curve for the cuts, which have no gain.
    private func point(of band: EQBand, in plot: CGRect) -> CGPoint {
        var shape = band
        shape.isOn = true
        let gain = band.kind.hasGain ? band.gain : shape.response(at: band.frequency, sampleRate: sampleRate)
        return CGPoint(x: x(of: band.frequency, in: plot), y: y(forGain: gain, in: plot))
    }

    private func updateHandles() {
        guard editsBands else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let plot = plot
        for band in equalizer.bands where band.id < handles.count {
            let handle = handles[band.id]
            let color = Self.bandColors[band.id % Self.bandColors.count]
            let lit = band.isOn && equalizer.isOn
            let center = point(of: band, in: plot)
            handle.position = center
            let grown = band.id == selected || band.id == hovered
            handle.setAffineTransform(CGAffineTransform(scaleX: grown ? 1.25 : 1, y: grown ? 1.25 : 1))
            handle.fillColor = lit ? color.cgColor : Self.background.cgColor
            handle.strokeColor = band.id == selected ? NSColor.white.cgColor : (lit ? color.cgColor : color.withAlphaComponent(0.7).cgColor)
            numbers[band.id].position = CGPoint(x: center.x, y: center.y - 0.5)
            numbers[band.id].foregroundColor = lit ? NSColor(white: 0, alpha: 0.75).cgColor : color.cgColor
        }
        if let selected, equalizer.bands.indices.contains(selected) {
            let band = equalizer.bands[selected]
            var parts = ["\(selected + 1). \(band.kind.title)", Self.frequencyText(band.frequency)]
            if band.kind.hasGain { parts.append(String(format: "%+.1f dB", band.gain)) }
            parts.append(String(format: "Q %.2f", band.q))
            if !band.isOn { parts.append("꺼짐") }
            readout.string = parts.joined(separator: "   ")
            readout.foregroundColor = Self.bandColors[selected % Self.bandColors.count].cgColor
            readout.frame = CGRect(x: plot.minX + 8, y: plot.maxY - 20, width: plot.width - 16, height: 15)
            readout.isHidden = false
        } else {
            readout.isHidden = true
        }
    }

    static func frequencyText(_ frequency: Double) -> String {
        frequency >= 1000 ? String(format: "%.2f kHz", frequency / 1000) : String(format: "%.0f Hz", frequency)
    }

    // MARK: - Mouse, for the EQ window

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The small display lets clicks through to the button around it.
        editsBands ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard editsBands else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    private func nearestBand(to location: CGPoint, within distance: CGFloat) -> Int? {
        let plot = plot
        var best: (id: Int, distance: CGFloat)?
        for band in equalizer.bands {
            let center = point(of: band, in: plot)
            let away = hypot(center.x - location.x, center.y - location.y)
            if away <= distance, away < (best?.distance ?? .infinity) { best = (band.id, away) }
        }
        return best?.id
    }

    private func setHovered(_ band: Int?) {
        guard band != hovered else { return }
        hovered = band
        updateHandles()
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(nearestBand(to: convert(event.locationInWindow, from: nil), within: 16))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard let id = nearestBand(to: location, within: 14) else {
            dragging = nil
            onSelect(nil)
            return
        }
        // A double click switches the band on or off.
        if event.clickCount == 2 {
            var band = equalizer.bands[id]
            band.isOn.toggle()
            onChange(band)
            dragging = nil
            return
        }
        let center = point(of: equalizer.bands[id], in: plot)
        dragging = (id, CGSize(width: center.x - location.x, height: center.y - location.y))
        onSelect(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let location = convert(event.locationInWindow, from: nil)
        let target = CGPoint(x: location.x + dragging.offset.width, y: location.y + dragging.offset.height)
        let plot = plot
        var band = equalizer.bands[dragging.band]
        band.frequency = Self.rounded(settings.frequency(at: Double((target.x - plot.minX) / plot.width)))
        if band.kind.hasGain {
            let gain = Double((target.y - plot.midY) / (plot.height / 2)) * gainRange
            // A little stickiness at 0 dB, so a band can be put back flat.
            band.gain = abs(gain) < 0.3 ? 0 : (gain * 10).rounded() / 10
        }
        band.isOn = true
        onChange(band)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    /// The scroll wheel changes the Q of the band under the pointer, or of the selected one.
    override func scrollWheel(with event: NSEvent) {
        guard editsBands else { return super.scrollWheel(with: event) }
        let location = convert(event.locationInWindow, from: nil)
        guard let id = nearestBand(to: location, within: 40) ?? selected else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        var band = equalizer.bands[id]
        band.q = (band.q * exp(Double(delta) * 0.012) * 100).rounded() / 100
        onChange(band)
        if selected != id { onSelect(id) }
    }

    static func rounded(_ frequency: Double) -> Double {
        frequency < 100 ? (frequency * 2).rounded() / 2 : frequency < 1000 ? frequency.rounded() : (frequency / 10).rounded() * 10
    }
}

/// The spectrum display for SwiftUI.
struct SpectrumDisplay: NSViewRepresentable {
    let player: PreviewPlayer
    let settings: SpectrumSettings
    let equalizer: EQSettings
    var editsBands = false
    var selected: Int?
    var onChange: (EQBand) -> Void = { _ in }
    var onSelect: (Int?) -> Void = { _ in }

    func makeNSView(context: Context) -> SpectrumNSView {
        let view = SpectrumNSView(editsBands: editsBands)
        view.player = player
        return view
    }

    func updateNSView(_ view: SpectrumNSView, context: Context) {
        view.player = player
        view.sampleRate = player.sampleRate
        view.settings = settings
        view.equalizer = equalizer
        view.selected = selected
        view.onChange = onChange
        view.onSelect = onSelect
    }

    static func dismantleNSView(_ view: SpectrumNSView, coordinator: ()) {
        view.player = nil
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
