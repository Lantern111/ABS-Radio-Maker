import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

/// The pictures in use for each layer. A replacement is copied into the app's own folder, so it stays even if the
/// original file is moved or deleted.
@MainActor @Observable final class LayerLibrary {
    private(set) var images: [LayerSlot: CGImage] = [:]
    private(set) var customSlots: Set<LayerSlot> = []
    /// Goes up whenever a picture changes, so anything drawn from them knows to start over.
    private(set) var revision = 0

    private let folder: URL

    init() {
        folder = URL.applicationSupportDirectory.appending(path: "ABS Radio Maker/Layers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for slot in LayerSlot.allCases { load(slot) }
    }

    static let acceptedTypes: [UTType] = [.png, .jpeg, .heic, .tiff, .webP, .image]

    func replace(_ slot: LayerSlot, with url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = FrameRenderer.loadImage(at: url) else { throw LayerError.unreadable }

        // Saved as PNG whatever it came in as, so transparency survives and the app only reads one kind of file.
        let destination = customURL(for: slot)
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LayerError.cannotSave
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw LayerError.cannotSave }
        load(slot)
    }

    func reset(_ slot: LayerSlot) {
        try? FileManager.default.removeItem(at: customURL(for: slot))
        load(slot)
    }

    private func customURL(for slot: LayerSlot) -> URL {
        folder.appending(path: "\(slot.rawValue).png")
    }

    private func load(_ slot: LayerSlot) {
        let custom = customURL(for: slot)
        if FileManager.default.fileExists(atPath: custom.path), let image = FrameRenderer.loadImage(at: custom) {
            images[slot] = image
            customSlots.insert(slot)
        } else {
            images[slot] = slot.defaultResource
                .flatMap { Bundle.main.url(forResource: $0, withExtension: "png") }
                .flatMap(FrameRenderer.loadImage(at:))
            customSlots.remove(slot)
        }
        revision += 1
    }

    enum LayerError: LocalizedError {
        case unreadable
        case cannotSave

        var errorDescription: String? {
            switch self {
            case .unreadable: "그림 파일을 열지 못했어요. PNG나 JPEG 파일인지 확인해 주세요."
            case .cannotSave: "그림을 저장하지 못했어요."
            }
        }
    }
}
