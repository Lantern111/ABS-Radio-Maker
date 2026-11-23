import CoreGraphics
import Foundation
import ImageIO

/// Draws one frame of the video: background, then the character in its pose, then the desk in front.
///
/// Every layer picture is drawn to fill the screen the same way, so pictures drawn on the same canvas line up. They're
/// scaled to the screen once, up front, and cut down to the part that isn't transparent, which keeps each frame quick.
final class FrameRenderer: @unchecked Sendable {
    let size: CGSize

    /// A picture scaled for the screen, and where it goes, with the origin at the top left.
    struct Placed {
        let image: CGImage
        let rect: CGRect
    }

    /// The pictures scaled to fill the screen. The preview shows these as layers; the export draws them.
    let background: CGImage?
    let musicBackground: CGImage?
    let desk: Placed?
    private let poses: [LayerSlot: Placed]
    /// The corner cover as it was given. It's fitted into the frame when drawn, because the frame can move.
    private let cover: CGImage?
    private let coverLock = NSLock()
    private var composedCover: Placed?
    /// The bottom middle of the character, which it sways around.
    private let pivot: CGPoint

    init(images: [LayerSlot: CGImage], size: CGSize) {
        self.size = size
        background = images[.background].flatMap { Self.filled($0, size: size, opaque: true) }
        musicBackground = images[.musicBackground].flatMap { Self.filled($0, size: size, opaque: true) }
        desk = images[.desk].flatMap { Self.placed($0, size: size) }
        cover = images[.cover]

        var poses = [LayerSlot: Placed]()
        for slot in LayerSlot.allCases where slot.isCharacterPose {
            if let image = images[slot], let placed = Self.placed(image, size: size) {
                poses[slot] = placed
            }
        }
        self.poses = poses
        if let base = poses[.character] {
            pivot = CGPoint(x: base.rect.midX, y: base.rect.maxY)
        } else {
            pivot = CGPoint(x: size.width / 2, y: size.height)
        }
    }

    // MARK: - Drawing

    /// Draws a frame into a context whose origin is at the bottom left, as Core Graphics contexts usually are.
    func draw(in context: CGContext, pose: Performance.Pose, settings: StudioSettings, quality: CGInterpolationQuality = .high) {
        draw(in: context, pose: pose, settings: settings, quality: quality, parts: .all, listening: pose.listening)
    }

    /// Which parts of a frame to draw. The export draws the parts that don't move once, and only the character, with the
    /// desk in front of it, in each frame.
    struct Parts: OptionSet {
        let rawValue: Int
        /// The background, the song background, and the corner cover.
        static let backdrop = Parts(rawValue: 1)
        static let character = Parts(rawValue: 2)
        static let desk = Parts(rawValue: 4)
        static let all: Parts = [.backdrop, .character, .desk]
    }

    /// `clip` keeps the drawing to part of the screen, in top-left-origin screen coordinates.
    func draw(
        in context: CGContext,
        pose: Performance.Pose,
        settings: StudioSettings,
        quality: CGInterpolationQuality = .high,
        parts: Parts,
        listening: Double,
        clip: CGRect? = nil
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = quality
        // From here on, the origin is at the top left.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if let clip { context.clip(to: clip) }

        let screen = CGRect(origin: .zero, size: size)
        if parts.contains(.backdrop) {
            if let background {
                draw(background, in: screen, context: context)
            } else {
                context.setFillColor(gray: 0.12, alpha: 1)
                context.fill(screen)
            }
            if let musicBackground, listening > 0 {
                context.saveGState()
                context.setAlpha(listening)
                draw(musicBackground, in: screen, context: context)
                context.restoreGState()
            }
            if let cover = coverArt(settings: settings) {
                draw(cover.image, in: cover.rect, context: context)
            }
        }

        if parts.contains(.character), let character = character(for: pose.drawing) {
            drawCharacter(character, pose: pose, settings: settings, context: context)
        }

        if parts.contains(.desk), let desk {
            draw(desk.image, in: desk.rect, context: context)
        }
    }

    /// The part of the screen the character covers in a pose, in whole pixels with a little room for smoothing at
    /// the edges, in top-left-origin screen coordinates. Nil without a character.
    func characterBox(pose: Performance.Pose, settings: StudioSettings) -> CGRect? {
        guard let character = character(for: pose.drawing) else { return nil }
        let box = character.rect
            .applying(characterTransform(pose: pose, settings: settings))
            .insetBy(dx: -3, dy: -3)
            .integral
            .intersection(CGRect(origin: .zero, size: size))
        return box.isNull || box.isEmpty ? nil : box
    }

    /// Whether the song background is part way in, which the export can't take from a backdrop made in advance.
    func isFading(_ pose: Performance.Pose) -> Bool {
        musicBackground != nil && pose.listening > 0.001 && pose.listening < 0.999
    }

    /// The corner cover, fitted into the frame on the wall, behind glass. Nil without a cover. Made again only when the
    /// frame changes size.
    func coverArt(settings: StudioSettings) -> Placed? {
        guard let cover else { return nil }
        let rect = settings.coverFrame.rect(in: size).integral
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        coverLock.lock()
        defer { coverLock.unlock() }
        if let composed = composedCover, composed.rect.size == rect.size {
            let moved = Placed(image: composed.image, rect: rect)
            composedCover = moved
            return moved
        }
        guard let image = Self.framed(cover, size: rect.size) else { return nil }
        let composed = Placed(image: image, rect: rect)
        composedCover = composed
        return composed
    }

    /// The cover fitted inside a frame of the given size with a thin mat around it, and a faint sheen across it like
    /// the glass in the background's frame.
    private static func framed(_ cover: CGImage, size: CGSize) -> CGImage? {
        guard let context = makeContext(size: size) else { return nil }
        context.interpolationQuality = .high
        let mat = min(size.width, size.height) * 0.04
        let room = CGRect(origin: .zero, size: size).insetBy(dx: mat, dy: mat)
        let scale = min(room.width / CGFloat(cover.width), room.height / CGFloat(cover.height))
        let fitted = CGSize(width: CGFloat(cover.width) * scale, height: CGFloat(cover.height) * scale)
        let place = CGRect(x: room.midX - fitted.width / 2, y: room.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        context.draw(cover, in: place)

        // Two light bands rising to the right, kept to the cover.
        context.clip(to: place)
        context.setFillColor(CGColor(gray: 1, alpha: 0.10))
        for (start, width) in [(0.18, 0.16), (0.42, 0.07)] {
            let band = CGMutablePath()
            let left = place.minX + place.width * start
            band.move(to: CGPoint(x: left, y: place.minY))
            band.addLine(to: CGPoint(x: left + place.width * width, y: place.minY))
            band.addLine(to: CGPoint(x: left + place.width * (width + 0.55), y: place.maxY))
            band.addLine(to: CGPoint(x: left + place.width * 0.55, y: place.maxY))
            band.closeSubpath()
            context.addPath(band)
        }
        context.fillPath()
        return context.makeImage()
    }

    /// The character's drawing for a pose. Without a picture of its own, listening uses the eyes-closed drawing, and
    /// anything else uses the plain one.
    func character(for drawing: LayerSlot) -> Placed? {
        if let placed = poses[drawing] { return placed }
        if drawing == .listening, let eyesClosed = poses[.blink] { return eyesClosed }
        return poses[.character]
    }

    /// Where the character's drawing goes for a pose: its position and size from the settings, then the sway around its
    /// feet. Works on top-left-origin screen coordinates.
    func characterTransform(pose: Performance.Pose, settings: StudioSettings) -> CGAffineTransform {
        let scale = settings.characterScale
        let offset = CGPoint(x: settings.characterOffsetX * size.width, y: settings.characterOffsetY * size.height)
        // The character grows and shrinks around the bottom middle of the screen, where it sits behind the desk.
        let anchor = CGPoint(x: size.width / 2 + offset.x, y: size.height + offset.y)
        let feet = CGPoint(
            x: anchor.x + (pivot.x - size.width / 2) * scale,
            y: anchor.y + (pivot.y - size.height) * scale
        )
        let lift = pose.lift * size.height / 1080
        return CGAffineTransform.identity
            .translatedBy(x: feet.x, y: feet.y + lift)
            .rotated(by: pose.rotation)
            .translatedBy(x: -feet.x, y: -feet.y)
            .translatedBy(x: anchor.x, y: anchor.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height)
    }

    func makeImage(pose: Performance.Pose, settings: StudioSettings, quality: CGInterpolationQuality = .medium) -> CGImage? {
        guard let context = Self.makeContext(size: size) else { return nil }
        draw(in: context, pose: pose, settings: settings, quality: quality)
        return context.makeImage()
    }

    private func drawCharacter(_ character: Placed, pose: Performance.Pose, settings: StudioSettings, context: CGContext) {
        context.saveGState()
        context.concatenate(characterTransform(pose: pose, settings: settings))
        draw(character.image, in: character.rect, context: context)
        context.restoreGState()
    }

    /// Draws an image the right way up in the flipped, top-left-origin context.
    private func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    // MARK: - Preparing the pictures

    static func makeContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    /// Where an image goes when it's scaled to fill the screen, cropping whatever overflows evenly on both sides.
    static func fillRect(for image: CGImage, size: CGSize) -> CGRect {
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let width = CGFloat(image.width) * scale
        let height = CGFloat(image.height) * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    /// The image scaled to fill the screen, as a picture exactly the screen's size.
    private static func filled(_ image: CGImage, size: CGSize, opaque: Bool) -> CGImage? {
        guard let context = makeContext(size: size) else { return nil }
        context.interpolationQuality = .high
        let rect = fillRect(for: image, size: size)
        // Core Graphics counts from the bottom; fillRect is centered, so flipping it changes nothing.
        context.draw(image, in: rect)
        return context.makeImage()
    }

    /// The image scaled to fill the screen, trimmed to the part that isn't transparent.
    private static func placed(_ image: CGImage, size: CGSize) -> Placed? {
        guard let context = makeContext(size: size) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: fillRect(for: image, size: size))
        guard let full = context.makeImage(), let data = context.data else { return nil }

        let width = Int(size.width)
        let height = Int(size.height)
        let bytesPerRow = context.bytesPerRow
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for row in 0..<height {
            let line = pixels + row * bytesPerRow
            var first = -1
            var last = -1
            for column in 0..<width where line[column * 4 + 3] > 0 {
                if first < 0 { first = column }
                last = column
            }
            if first >= 0 {
                minX = min(minX, first)
                maxX = max(maxX, last)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // The context's rows run top to bottom in memory, which is the top-left-origin rect we want.
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = full.cropping(to: bounds) else { return nil }
        return Placed(image: cropped, rect: bounds)
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
