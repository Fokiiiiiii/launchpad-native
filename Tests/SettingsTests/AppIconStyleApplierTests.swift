import AppKit
import ImageIO
import Persistence
import Testing
import UniformTypeIdentifiers
@testable import Settings

/// A variant the way the bundle ships them: 1024x1024.
@MainActor
private func variantsDirectory(with style: AppIconStyle) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let context = try #require(CGContext(
        data: nil, width: 1_024, height: 1_024, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 1_024))
    let image = try #require(context.makeImage())
    let url = directory.appendingPathComponent("\(style.rawValue).png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return directory
}

private func pixelWidth(of image: NSImage) -> Int? {
    image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
}

/// The style picker draws each variant at 40pt. Decoding the 1024px file whole
/// kept 4MB per variant in memory; at twice the drawn size it is 80px.
@Test @MainActor func anIconVariantIsDecodedAtTheSizeItIsDrawnAt() throws {
    let directory = try variantsDirectory(with: .monochrome)
    defer { try? FileManager.default.removeItem(at: directory) }

    let image = try #require(AppIconStyleApplier.image(for: .monochrome, pointSize: 40, in: directory))

    #expect(image.size == NSSize(width: 40, height: 40))
    #expect(pixelWidth(of: image) == 80)
}

/// SwiftUI asks again on every redraw of Settings; the file is read once.
@Test @MainActor func anIconVariantIsReadOncePerSize() throws {
    let directory = try variantsDirectory(with: .solid)
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try #require(AppIconStyleApplier.image(for: .solid, pointSize: 40, in: directory))
    let second = try #require(AppIconStyleApplier.image(for: .solid, pointSize: 40, in: directory))
    #expect(first === second)

    let larger = try #require(AppIconStyleApplier.image(for: .solid, pointSize: 76, in: directory))
    #expect(larger !== first)
    #expect(pixelWidth(of: larger) == 152)
}

/// A missing variant leaves the caller to fall back, as before: the picker
/// shows an empty image and `apply` restores the bundle's own icon.
@Test @MainActor func aMissingIconVariantGivesNoImage() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(AppIconStyleApplier.image(for: .classic, pointSize: 40, in: directory) == nil)
}
