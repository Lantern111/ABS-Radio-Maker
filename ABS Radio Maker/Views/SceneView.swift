import AppKit
import QuartzCore
import SwiftUI

/// The preview of the scene, built from Core Animation layers so the graphics card stacks the pictures. Each frame
/// only swaps the character's drawing and moves it, instead of redrawing the whole screen.
struct SceneView: NSViewRepresentable {
    let studio: Studio
    /// Seconds into the idle loop, for when no recording is open. With a recording, the player's position is used.
    var idleTime: Double?

    func makeNSView(context: Context) -> SceneNSView {
        SceneNSView()
    }

    func updateNSView(_ view: SceneNSView, context: Context) {
        // With a recording, the view follows the player on the player's own clock; this only brings in new pictures,
        // settings, and mouth.
        view.follow(idleTime == nil ? studio : nil)
        let time = idleTime ?? studio.player.time
        view.show(renderer: studio.sceneRenderer, pose: studio.pose(at: time), settings: studio.settings)
    }

    static func dismantleNSView(_ view: SceneNSView, coordinator: ()) {
        view.follow(nil)
    }
}

final class SceneNSView: NSView, PlaybackDisplay {
    private weak var studio: Studio?

    /// Shows what the character does at the player's position as it plays, or stops following with nil.
    func follow(_ studio: Studio?) {
        guard studio !== self.studio else { return }
        self.studio?.player.removeDisplay(self)
        self.studio = studio
        studio?.player.addDisplay(self)
    }

    var isShowing: Bool {
        guard let window, window.isVisible, window.occlusionState.contains(.visible) else { return false }
        return !isHiddenOrHasHiddenAncestor
    }

    var showsSpectrum: Bool { false }

    func refresh() {
        guard let studio else { return }
        show(renderer: studio.sceneRenderer, pose: studio.pose(at: studio.player.time), settings: studio.settings)
    }

    private let canvas = CALayer()
    private let backgroundLayer = CALayer()
    private let musicBackgroundLayer = CALayer()
    private let coverLayer = CALayer()
    private let characterLayer = CALayer()
    private let deskLayer = CALayer()
    private weak var renderer: FrameRenderer?
    private var shownCharacter: CGImage?
    private var shownCover: CGImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        canvas.bounds = CGRect(origin: .zero, size: VideoExporter.size)
        // Top-left origin, the same as the renderer's coordinates.
        canvas.isGeometryFlipped = true
        canvas.masksToBounds = true
        canvas.backgroundColor = CGColor(gray: 0.12, alpha: 1)
        for sublayer in [backgroundLayer, musicBackgroundLayer, coverLayer, characterLayer, deskLayer] {
            sublayer.contentsGravity = .resize
            sublayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "transform": NSNull(), "opacity": NSNull()]
            canvas.addSublayer(sublayer)
        }
        backgroundLayer.frame = canvas.bounds
        musicBackgroundLayer.frame = canvas.bounds
        musicBackgroundLayer.opacity = 0
        layer?.addSublayer(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        // Fits the 16:9 screen into the view, centered.
        let size = VideoExporter.size
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        CATransaction.commit()
    }

    func show(renderer: FrameRenderer, pose: Performance.Pose, settings: StudioSettings) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if renderer !== self.renderer {
            self.renderer = renderer
            backgroundLayer.contents = renderer.background
            musicBackgroundLayer.contents = renderer.musicBackground
            if let desk = renderer.desk {
                deskLayer.contents = desk.image
                deskLayer.frame = desk.rect
            } else {
                deskLayer.contents = nil
            }
        }
        musicBackgroundLayer.opacity = renderer.musicBackground == nil ? 0 : Float(pose.listening)

        if let cover = renderer.coverArt(settings: settings) {
            if shownCover !== cover.image {
                coverLayer.contents = cover.image
                shownCover = cover.image
            }
            coverLayer.frame = cover.rect
        } else if shownCover != nil {
            coverLayer.contents = nil
            shownCover = nil
        }

        guard let character = renderer.character(for: pose.drawing) else {
            characterLayer.contents = nil
            shownCharacter = nil
            return
        }
        if shownCharacter !== character.image {
            characterLayer.contents = character.image
            shownCharacter = character.image
        }
        // A layer's transform turns it around its center, while the renderer's works on screen coordinates. For a
        // point p, the layer gives center + A(p - center) + offset and the renderer gives A p + t, so the offset is
        // t - center + A center.
        characterLayer.setAffineTransform(.identity)
        characterLayer.frame = character.rect
        let transform = renderer.characterTransform(pose: pose, settings: settings)
        let center = CGPoint(x: character.rect.midX, y: character.rect.midY)
        let turnedCenter = CGPoint(
            x: transform.a * center.x + transform.c * center.y,
            y: transform.b * center.x + transform.d * center.y
        )
        characterLayer.setAffineTransform(CGAffineTransform(
            a: transform.a, b: transform.b, c: transform.c, d: transform.d,
            tx: transform.tx - center.x + turnedCenter.x,
            ty: transform.ty - center.y + turnedCenter.y
        ))
    }
}
