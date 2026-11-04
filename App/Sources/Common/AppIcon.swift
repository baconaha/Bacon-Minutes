import AppKit
import Observation
import SwiftUI

/// One icon for the Dock and every in-app logo. A user-uploaded image replaces both.
@MainActor
@Observable
final class AppIconStore {
    static let shared = AppIconStore()

    /// Square artwork without margins (rounded corners are applied when drawn).
    private(set) var customArtwork: NSImage?

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("LocalMinutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("custom-icon.png")
        if let img = NSImage(contentsOf: fileURL) { customArtwork = img }
    }

    /// Default artwork shipped in the asset catalog (same design as the app icon).
    var artwork: NSImage {
        customArtwork ?? NSImage(named: "LogoMark") ?? NSApp.applicationIconImage
    }

    /// Sets the Dock icon for this run. With no custom icon the bundle icon is used.
    func applyToDock() {
        NSApp.applicationIconImage = customArtwork.map(Self.dockIcon(from:))
    }

    func setCustom(from url: URL) throws {
        let access = ScopedAccess(url: url)
        defer { access.stop() }
        guard let source = NSImage(contentsOf: url), let normalized = Self.normalizedArtwork(source),
              let png = Self.pngData(normalized) else {
            throw IconError(message: "无法读取这张图片")
        }
        try png.write(to: fileURL, options: .atomic)
        customArtwork = normalized
        applyToDock()
    }

    func resetToDefault() {
        try? FileManager.default.removeItem(at: fileURL)
        customArtwork = nil
        applyToDock()
    }

    struct IconError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Image processing

    /// Crops transparent margins, then center-crops to a 1024×1024 square.
    static func normalizedArtwork(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        let step = max(1, min(rep.pixelsWide, rep.pixelsHigh) / 256)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 1) > 0.1 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                x += step
            }
            y += step
        }
        var crop = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        if maxX >= minX && maxY >= minY {
            crop = CGRect(x: minX, y: minY, width: maxX - minX + step, height: maxY - minY + step)
                .intersection(crop)
        }
        let side = min(crop.width, crop.height)
        let square = CGRect(x: crop.midX - side / 2, y: crop.midY - side / 2, width: side, height: side).integral
        guard let cropped = cg.cropping(to: square) else { return nil }
        let out = NSImage(size: NSSize(width: 1024, height: 1024))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cropped, size: .zero).draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        out.unlockFocus()
        return out
    }

    /// macOS icon grid: 824pt rounded body on a 1024 canvas with a soft shadow.
    static func dockIcon(from artwork: NSImage) -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            let body = NSRect(x: 100, y: 112, width: 824, height: 824)
            let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            artwork.draw(in: body)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
