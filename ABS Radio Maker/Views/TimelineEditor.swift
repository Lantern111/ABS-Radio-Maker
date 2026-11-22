import AppKit
import QuartzCore
import SwiftUI

enum TimelineTool: String, CaseIterable, Identifiable {
    /// A: move the playhead, select stretches, drag borders.
    case select
    /// B: click to cut a stretch in two.
    case blade

    var id: String { rawValue }
}

/// Which part of the recording the timeline shows, the tool in use, and what's selected. The buttons around the
/// timeline and the keyboard use it too.
@MainActor @Observable final class TimelineViewport {
    /// Seconds at the left edge.
    var start: Double = 0
    /// How zoomed in. 0 shows the whole recording.
    var pointsPerSecond: Double = 0
    /// A stretch of the edited audio picked in the talk-and-song lane, or with I and O.
    var selection: ClosedRange<Double>?
    var tool = TimelineTool.select

    /// Kept up to date by the timeline view.
    var width: Double = 600
    var duration: Double = 0

    static let mostPointsPerSecond = 400.0

    var fittingPointsPerSecond: Double {
        duration > 0 ? max(width, 1) / duration : 1
    }

    var effectivePointsPerSecond: Double {
        max(pointsPerSecond, fittingPointsPerSecond)
    }

    var visibleDuration: Double { width / effectivePointsPerSecond }

    var isShowingAll: Bool { pointsPerSecond <= fittingPointsPerSecond * 1.001 }

    /// Zooms in (factor above 1) or out, keeping `anchor` where it is on screen. Without an anchor, keeps the middle.
    func zoom(by factor: Double, around anchor: Double? = nil) {
        guard duration > 0 else { return }
        let current = effectivePointsPerSecond
        let anchor = anchor ?? (start + visibleDuration / 2)
        let offset = (anchor - start) * current
        let new = min(max(current * factor, fittingPointsPerSecond), Self.mostPointsPerSecond)
        pointsPerSecond = new
        start = anchor - offset / new
        clampStart()
    }

    func showAll() {
        pointsPerSecond = 0
        start = 0
    }

    func scroll(bySeconds seconds: Double) {
        start += seconds
        clampStart()
    }

    /// Moves just enough to bring a time into view.
    func reveal(_ time: Double) {
        if time < start || time > start + visibleDuration * 0.97 {
            start = time - visibleDuration * 0.05
            clampStart()
        }
    }

    func clampStart() {
        let clamped = min(max(start, 0), max(duration - visibleDuration, 0))
        if clamped != start { start = clamped }
    }

    /// I and O: marks where a selection starts or ends.
    func markStart(at time: Double) {
        let end = selection?.upperBound ?? duration
        selection = time < end ? time...end : time...duration
    }

    func markEnd(at time: Double) {
        let start = selection?.lowerBound ?? 0
        selection = start < time ? start...time : 0...time
    }
}

/// The edited recording laid out in time: a ruler, the talk-and-song lane, and the waveform.
struct TimelineEditor: NSViewRepresentable {
    let studio: Studio

    func makeNSView(context: Context) -> TimelineNSView {
        let view = TimelineNSView(viewport: studio.timeline)
        view.player = studio.player
        return view
    }

    static func dismantleNSView(_ view: TimelineNSView, coordinator: ()) {
        view.player = nil
    }

    func updateNSView(_ view: TimelineNSView, context: Context) {
        let viewport = studio.timeline
        view.onSeek = { studio.jump(to: $0) }
        view.onMoveBorder = { studio.moveSegmentBorder(from: $0, to: $1) }
        view.onSetSegment = { studio.setSegment(from: $0, to: $1, isMusic: $2) }
        view.onSplit = { studio.splitSegment(at: $0) }
        view.onRemoveBorder = { studio.removeBorder(near: $0) }
        view.onRestore = { studio.restoreDetectedSegments() }
        // Only what changed is redrawn: the playhead moves on its own layer, 30 times a second while playing.
        view.setContent(
            hasRecording: studio.hasRecording,
            duration: studio.player.duration,
            peaks: studio.peaks,
            peaksPerSecond: Studio.peaksPerSecond,
            segments: studio.timelineSegments,
            canRestore: studio.segmentsWereEdited,
            view: TimelineNSView.ViewState(
                start: viewport.start,
                pointsPerSecond: viewport.pointsPerSecond,
                selection: viewport.selection,
                tool: viewport.tool
            )
        )
        view.setPlayhead(studio.player.time, isPlaying: studio.player.isPlaying)
    }
}

final class TimelineNSView: NSView, PlaybackDisplay {
    /// The playhead follows the player on the player's own clock.
    weak var player: PreviewPlayer? {
        didSet {
            guard player !== oldValue else { return }
            oldValue?.removeDisplay(self)
            player?.addDisplay(self)
        }
    }

    var isShowing: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor
    }

    var showsSpectrum: Bool { false }

    func refresh() {
        guard let player else { return }
        setPlayhead(player.time, isPlaying: player.isPlaying)
    }

    struct ViewState: Equatable {
        var start: Double
        var pointsPerSecond: Double
        var selection: ClosedRange<Double>?
        var tool: TimelineTool
    }

    let viewport: TimelineViewport

    var onSeek: (Double) -> Void = { _ in }
    var onMoveBorder: (Double, Double) -> Void = { _, _ in }
    var onSetSegment: (Double, Double, Bool) -> Void = { _, _, _ in }
    var onSplit: (Double) -> Void = { _ in }
    var onRemoveBorder: (Double) -> Void = { _ in }
    var onRestore: () -> Void = {}

    static let talkColor = NSColor(srgbRed: 0.33, green: 0.56, blue: 0.95, alpha: 1)
    static let songColor = NSColor(srgbRed: 0.93, green: 0.42, blue: 0.62, alpha: 1)

    private var hasRecording = false
    private var duration: Double = 0
    private var peaks: [Float] = []
    private var peaksPerSecond = 100.0
    private var segments: [ContentSegment] = []
    private var canRestore = false
    private var shownState: ViewState?
    private var playhead: Double = 0

    private let playheadLayer = CALayer()
    private let bladeLayer = CALayer()

    private let rulerHeight: CGFloat = 20
    private let laneHeight: CGFloat = 26
    private let borderReach: CGFloat = 5

    private enum Drag {
        case scrubbing
        case border(from: Double, to: Double)
        case selecting(anchor: Double, moved: Bool)
    }

    private var drag: Drag?
    /// After the person scrolls or zooms, the view stops following the playhead for a moment.
    private var lastManualMove = Date.distantPast

    init(viewport: TimelineViewport) {
        self.viewport = viewport
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for overlay in [playheadLayer, bladeLayer] {
            overlay.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
            overlay.zPosition = 10
            layer?.addSublayer(overlay)
        }
        bladeLayer.backgroundColor = NSColor.systemYellow.cgColor
        bladeLayer.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Content

    func setContent(
        hasRecording: Bool,
        duration: Double,
        peaks: [Float],
        peaksPerSecond: Double,
        segments: [ContentSegment],
        canRestore: Bool,
        view: ViewState
    ) {
        // The peaks are compared by their storage, not value by value: a new array means new audio.
        let samePeaks = peaks.count == self.peaks.count && peaks.withUnsafeBufferPointer { new in
            self.peaks.withUnsafeBufferPointer { $0.baseAddress == new.baseAddress }
        }
        guard hasRecording != self.hasRecording
            || duration != self.duration
            || !samePeaks
            || segments != self.segments
            || canRestore != self.canRestore
            || view != shownState
        else { return }

        self.hasRecording = hasRecording
        self.duration = duration
        self.peaks = peaks
        self.peaksPerSecond = peaksPerSecond
        self.segments = segments
        self.canRestore = canRestore
        shownState = view
        viewport.width = bounds.width
        viewport.duration = duration
        viewport.clampStart()
        needsDisplay = true
        positionPlayhead()
    }

    func setPlayhead(_ time: Double, isPlaying: Bool) {
        playhead = time
        if isPlaying, drag == nil, Date().timeIntervalSince(lastManualMove) > 2 {
            // Turning the page goes through the viewport, which redraws the timeline.
            viewport.reveal(time)
        }
        positionPlayhead()
    }

    private func positionPlayhead() {
        let x = x(for: playhead)
        playheadLayer.isHidden = !hasRecording || x < -2 || x > bounds.width + 2
        playheadLayer.frame = CGRect(x: x - 1, y: 0, width: 2, height: bounds.height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        viewport.width = newSize.width
        viewport.clampStart()
        needsDisplay = true
        positionPlayhead()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Geometry

    private var pointsPerSecond: Double { viewport.effectivePointsPerSecond }
    private var laneRect: CGRect { CGRect(x: 0, y: rulerHeight, width: bounds.width, height: laneHeight) }
    private var waveRect: CGRect {
        CGRect(x: 0, y: rulerHeight + laneHeight, width: bounds.width, height: max(bounds.height - rulerHeight - laneHeight, 0))
    }

    private func x(for time: Double) -> CGFloat { CGFloat((time - viewport.start) * pointsPerSecond) }

    private func time(at x: CGFloat) -> Double {
        min(max(viewport.start + Double(x) / pointsPerSecond, 0), duration)
    }

    private func borderTime(near point: CGPoint) -> Double? {
        guard laneRect.insetBy(dx: 0, dy: -4).contains(point) else { return nil }
        return segments.dropFirst()
            .map(\.start)
            .filter { abs(x(for: $0) - point.x) <= borderReach }
            .min { abs(x(for: $0) - point.x) < abs(x(for: $1) - point.x) }
    }

    private func segment(at time: Double) -> ContentSegment? {
        segments.first { $0.start <= time && time < $0.end } ?? segments.last
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The playhead's color follows light and dark mode; it's set here because drawing runs in the right appearance.
        playheadLayer.backgroundColor = NSColor.labelColor.cgColor

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard hasRecording, duration > 0 else {
            drawText("녹음 파일을 열면 여기에 파형이 보여요", at: CGPoint(x: 12, y: bounds.midY - 8), color: .secondaryLabelColor, size: 12)
            return
        }

        let visibleEnd = viewport.start + viewport.visibleDuration
        drawRuler(until: visibleEnd)

        // Talk and song: solid in the lane, faint behind the waveform.
        for segment in segments where segment.end > viewport.start && segment.start < visibleEnd {
            let left = max(x(for: segment.start), -2)
            let right = min(x(for: segment.end), bounds.width + 2)
            let color = segment.isMusic ? Self.songColor : Self.talkColor
            color.withAlphaComponent(0.85).setFill()
            CGRect(x: left, y: laneRect.minY + 2, width: right - left, height: laneHeight - 4).fill()
            color.withAlphaComponent(0.13).setFill()
            CGRect(x: left, y: waveRect.minY, width: right - left, height: waveRect.height).fill()
            if right - left > 44 {
                let label = segment.isMusic ? "노래" : "말하기"
                drawText(label, at: CGPoint(x: max(left, 0) + 6, y: laneRect.minY + 6), color: .white, size: 11, weight: .semibold)
            }
        }
        // Borders, which can be dragged.
        NSColor.white.withAlphaComponent(0.9).setFill()
        for segment in segments.dropFirst() where segment.start >= viewport.start && segment.start <= visibleEnd {
            CGRect(x: x(for: segment.start) - 1.5, y: laneRect.minY, width: 3, height: laneHeight).fill()
        }

        drawWaveform()

        if let selection = viewport.selection {
            let left = x(for: selection.lowerBound)
            let right = x(for: selection.upperBound)
            let rect = CGRect(x: left, y: laneRect.minY, width: max(right - left, 1), height: bounds.height - laneRect.minY)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            rect.fill()
            NSColor.controlAccentColor.setFill()
            CGRect(x: left - 1, y: rect.minY, width: 2, height: rect.height).fill()
            CGRect(x: right - 1, y: rect.minY, width: 2, height: rect.height).fill()
        }

        if case .border(_, let to) = drag {
            NSColor.controlAccentColor.setFill()
            CGRect(x: x(for: to) - 1.5, y: laneRect.minY, width: 3, height: bounds.height - laneRect.minY).fill()
            drawText(TimeText.format(to, precise: true), at: CGPoint(x: x(for: to) + 5, y: 3), color: .labelColor, size: 10, weight: .semibold)
        }
    }

    private func drawRuler(until visibleEnd: Double) {
        // The tick spacing that keeps labels about 80 points apart.
        let choices: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let spacing = choices.first { $0 * pointsPerSecond >= 80 } ?? 600
        var tick = (viewport.start / spacing).rounded(.down) * spacing
        NSColor.separatorColor.setFill()
        CGRect(x: 0, y: rulerHeight - 1, width: bounds.width, height: 1).fill()
        while tick <= visibleEnd {
            let tickX = x(for: tick)
            NSColor.tertiaryLabelColor.setFill()
            CGRect(x: tickX, y: rulerHeight - 7, width: 1, height: 6).fill()
            drawText(TimeText.format(tick, precise: spacing < 1), at: CGPoint(x: tickX + 3, y: 3), color: .secondaryLabelColor, size: 10)
            for step in 1..<4 {
                let minorX = x(for: tick + spacing * Double(step) / 4)
                CGRect(x: minorX, y: rulerHeight - 4, width: 1, height: 3).fill()
            }
            tick += spacing
        }
    }

    private func drawWaveform() {
        guard !peaks.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let middle = waveRect.midY
        let halfHeight = waveRect.height / 2 - 3
        let path = CGMutablePath()
        // One bar per point across, from the loudest peak that falls under it.
        peaks.withUnsafeBufferPointer { peaks in
            var column: CGFloat = 0
            while column < bounds.width {
                let from = Int(((viewport.start + Double(column) / pointsPerSecond) * peaksPerSecond).rounded(.down))
                let to = max(from + 1, Int(((viewport.start + Double(column + 1) / pointsPerSecond) * peaksPerSecond).rounded(.down)))
                guard from < peaks.count else { break }
                var peak: Float = 0
                for index in max(from, 0)..<min(to, peaks.count) where peaks[index] > peak { peak = peaks[index] }
                let height = max(CGFloat(peak) * halfHeight, 0.5)
                path.addRect(CGRect(x: column, y: middle - height, width: 0.85, height: height * 2))
                column += 1
            }
        }
        context.addPath(path)
        context.setFillColor(NSColor.labelColor.withAlphaComponent(0.55).cgColor)
        context.fillPath()
    }

    private func drawText(_ text: String, at point: CGPoint, color: NSColor, size: CGFloat, weight: NSFont.Weight = .regular) {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]).draw(at: point)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A click can be routed here from elsewhere in the window; only clicks on the timeline count.
        guard hasRecording, bounds.contains(point) else { return }
        if viewport.tool == .blade {
            onSplit(time(at: point.x))
            return
        }
        if let border = borderTime(near: point) {
            drag = .border(from: border, to: border)
        } else if laneRect.contains(point) {
            drag = .selecting(anchor: time(at: point.x), moved: false)
        } else {
            drag = .scrubbing
            viewport.selection = nil
            onSeek(time(at: point.x))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        autoscroll(at: point)
        let current = time(at: point.x)
        switch drag {
        case .scrubbing:
            onSeek(current)
        case .border(let from, _):
            drag = .border(from: from, to: current)
        case .selecting(let anchor, let moved):
            let movedNow = moved || abs(x(for: anchor) - point.x) > 3
            drag = .selecting(anchor: anchor, moved: movedNow)
            if movedNow {
                viewport.selection = min(anchor, current)...max(anchor, current)
            }
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .border(let from, let to) where abs(x(for: from) - x(for: to)) > 1:
            onMoveBorder(from, to)
        case .selecting(_, false):
            // A click picks the whole stretch under the pointer.
            if let segment = segment(at: time(at: point.x)) {
                viewport.selection = segment.start...min(segment.end, duration)
            }
        default:
            break
        }
        drag = nil
        needsDisplay = true
    }

    /// Scrolls along when a drag reaches the edge.
    private func autoscroll(at point: CGPoint) {
        let edge: CGFloat = 20
        if point.x < edge {
            viewport.scroll(bySeconds: -Double(edge - point.x) / pointsPerSecond)
        } else if point.x > bounds.width - edge {
            viewport.scroll(bySeconds: Double(point.x - bounds.width + edge) / pointsPerSecond)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard hasRecording else { return }
        lastManualMove = Date()
        let point = convert(event.locationInWindow, from: nil)
        let precise = event.hasPreciseScrollingDeltas
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let amount = precise ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            viewport.zoom(by: pow(1.01, Double(amount)), around: time(at: point.x))
        } else {
            // Sideways scrolling moves along; a plain mouse wheel's up and down does too.
            var amount = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            if !precise { amount *= 12 }
            viewport.scroll(bySeconds: -Double(amount) / pointsPerSecond)
        }
    }

    override func magnify(with event: NSEvent) {
        guard hasRecording else { return }
        lastManualMove = Date()
        let point = convert(event.locationInWindow, from: nil)
        viewport.zoom(by: 1 + Double(event.magnification), around: time(at: point.x))
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updatePointer(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updatePointer(for: event)
    }

    override func mouseExited(with event: NSEvent) {
        bladeLayer.isHidden = true
        NSCursor.arrow.set()
    }

    private func updatePointer(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard hasRecording, bounds.contains(point) else {
            bladeLayer.isHidden = true
            return
        }
        if viewport.tool == .blade {
            // A yellow line shows where the cut will go.
            bladeLayer.isHidden = false
            bladeLayer.frame = CGRect(x: point.x - 0.5, y: laneRect.minY, width: 1, height: bounds.height - laneRect.minY)
            NSCursor.crosshair.set()
        } else {
            bladeLayer.isHidden = true
            if borderTime(near: point) != nil {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }

    // MARK: - Right-click menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard hasRecording else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let clicked = time(at: point.x)
        let menu = NSMenu()

        if let border = borderTime(near: point) {
            menu.addItem(ActionItem("이 경계 지우기") { [weak self] in self?.onRemoveBorder(border) })
            menu.addItem(.separator())
        }

        var range: ClosedRange<Double>?
        var subject = ""
        if let selection = viewport.selection, selection.contains(clicked) {
            range = selection
            subject = "선택한 구간을"
        } else if let segment = segment(at: clicked) {
            range = segment.start...min(segment.end, duration)
            subject = "이 구간을"
        }
        if let range {
            menu.addItem(ActionItem("\(subject) 노래로 바꾸기") { [weak self] in
                self?.onSetSegment(range.lowerBound, range.upperBound, true)
            })
            menu.addItem(ActionItem("\(subject) 말하기로 바꾸기") { [weak self] in
                self?.onSetSegment(range.lowerBound, range.upperBound, false)
            })
        }
        menu.addItem(ActionItem("여기서 자르기") { [weak self] in self?.onSplit(clicked) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("여기로 재생 위치 옮기기") { [weak self] in self?.onSeek(clicked) })
        if viewport.selection != nil {
            menu.addItem(ActionItem("선택 해제") { [weak self] in self?.viewport.selection = nil })
        }
        if canRestore {
            menu.addItem(.separator())
            menu.addItem(ActionItem("자동으로 찾은 대로 되돌리기") { [weak self] in self?.onRestore() })
        }
        return menu
    }
}

/// A menu item that runs a closure.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func run() {
        handler()
    }
}
