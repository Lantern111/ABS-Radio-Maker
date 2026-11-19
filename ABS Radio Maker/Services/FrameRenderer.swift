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
    /// The bottom middle of the character, which it sways around.
    private let pivot: CGPoint

    init(images: [LayerSlot: CGImage], size: CGSize) {
        self.size = size
        background = images[.background].flatMap { Self.filled($0, size: size, opaque: true) }
        musicBackground = images[.musicBackground].flatMap { Self.filled($0, size: size, opaque: true) }
        desk = images[.desk].flatMap { Self.placed($0, size: size) }

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
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = quality
        // From here on, the origin is at the top left.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let screen = CGRect(origin: .zero, size: size)
        if let background {
            draw(background, in: screen, context: context)
        } else {
            context.setFillColor(gray: 0.12, alpha: 1)
            context.fill(screen)
        }
        if let musicBackground, pose.listening > 0 {
            context.saveGState()
            context.setAlpha(pose.listening)
            draw(musicBackground, in: screen, context: context)
            context.restoreGState()
        }

        if let character = character(for: pose.drawing) {
            drawCharacter(character, pose: pose, settings: settings, context: context)
        }

        if let desk {
            draw(desk.image, in: desk.rect, context: context)
        }
    }

    /// The character's drawing for a pose, falling back to the plain drawing when that pose has no picture.
    func character(for drawing: LayerSlot) -> Placed? {
        poses[drawing] ?? poses[.character]
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
