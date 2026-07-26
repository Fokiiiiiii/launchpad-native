// One-off tool: draws this project's own app icon(s) (never Apple's
// Launchpad artwork — that asset doesn't exist anywhere on a modern macOS
// install to begin with, confirmed by inspecting Dock.app's Assets.car).
// All variants are original compositions.
//
// Usage:
//   swift run IconGenerator iconset <output-iconset-dir>
//     Draws the "classic" style at every required size (unchanged from
//     before variants existed) — feed the result to `iconutil -c icns` to
//     rebuild Resources/AppIcon.icns.
//   swift run IconGenerator variants <output-dir>
//     Draws one representative 512x512 PNG per `AppIconStyle` case into
//     <output-dir>/<style>.png — these are what Settings' App Icon picker
//     loads at runtime via `NSApp.applicationIconImage` (switching the
//     actual on-disk bundle icon isn't possible for an unsigned build
//     without re-signing, so this is the live-switchable representation).
import AppKit
import Foundation

enum Style: String, CaseIterable {
    case classic
    case monochrome
    case solid
    case diagonal
}

struct IconSpec {
    let fileName: String
    let pixelSize: Int
}

let iconsetSpecs: [IconSpec] = [
    IconSpec(fileName: "icon_16x16.png", pixelSize: 16),
    IconSpec(fileName: "icon_16x16@2x.png", pixelSize: 32),
    IconSpec(fileName: "icon_32x32.png", pixelSize: 32),
    IconSpec(fileName: "icon_32x32@2x.png", pixelSize: 64),
    IconSpec(fileName: "icon_128x128.png", pixelSize: 128),
    IconSpec(fileName: "icon_128x128@2x.png", pixelSize: 256),
    IconSpec(fileName: "icon_256x256.png", pixelSize: 256),
    IconSpec(fileName: "icon_256x256@2x.png", pixelSize: 512),
    IconSpec(fileName: "icon_512x512.png", pixelSize: 512),
    IconSpec(fileName: "icon_512x512@2x.png", pixelSize: 1024)
]

func drawIcon(style: Style, pixelSize: Int) -> NSImage {
    let size = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(backgroundPath)
    ctx.clip()
    drawBackground(style: style, ctx: ctx, size: size)
    ctx.restoreGState()

    drawForeground(style: style, ctx: ctx, size: size)

    image.unlockFocus()
    return image
}

private func drawBackground(style: Style, ctx: CGContext, size: CGFloat) {
    let colors: [CGColor]
    switch style {
    case .classic:
        // Blue -> purple, matching this project's Liquid Glass color
        // language rather than copying any real app's icon.
        colors = [
            NSColor(calibratedRed: 0.29, green: 0.40, blue: 0.88, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.54, green: 0.31, blue: 0.88, alpha: 1.0).cgColor
        ]
    case .monochrome:
        // Graphite gradient — dark, neutral, for users who want the icon
        // to disappear into a dark Dock/menu bar rather than stand out.
        colors = [
            NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor,
            NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor
        ]
    case .solid:
        // Flat single accent color — no gradient at all, the plainest of
        // the four options.
        colors = [
            NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.45, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.45, alpha: 1.0).cgColor
        ]
    case .diagonal:
        // Warm orange -> pink, diagonal corner-to-corner instead of top-
        // to-bottom, so it reads as visually distinct from `.classic` at
        // a glance even before the foreground pattern differs.
        colors = [
            NSColor(calibratedRed: 0.96, green: 0.55, blue: 0.20, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.92, green: 0.28, blue: 0.45, alpha: 1.0).cgColor
        ]
    }
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
        // Same top-left -> bottom-right direction for every style — visual
        // differentiation between styles comes from color + the foreground
        // pattern, not the gradient angle.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }

    // Soft top highlight — a subtle lighter wash near the top, evoking a
    // glass surface catching light without a hard edge. Same for every
    // style — it's what ties them together as one family.
    let highlightColors = [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ]
    if let highlightGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: highlightColors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(
            highlightGradient,
            start: CGPoint(x: size / 2, y: size),
            end: CGPoint(x: size / 2, y: size * 0.45),
            options: []
        )
    }
}

private func drawForeground(style: Style, ctx: CGContext, size: CGFloat) {
    switch style {
    case .classic:
        drawGrid(ctx: ctx, size: size, columns: 3, colors: rainbowColors, monochromeAlpha: nil)
    case .monochrome:
        drawGrid(ctx: ctx, size: size, columns: 3, colors: Array(repeating: NSColor.white, count: 9), monochromeAlpha: 0.75)
    case .solid:
        // A different grid entirely — 2x2 larger squares, not 3x3 — so
        // `.solid` reads as a distinct pattern, not just a recolored
        // `.classic`.
        drawGrid(ctx: ctx, size: size, columns: 2, colors: Array(repeating: NSColor.white, count: 4), monochromeAlpha: 0.85)
    case .diagonal:
        drawQuincunx(ctx: ctx, size: size)
    }
}

private let rainbowColors: [NSColor] = [
    NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.42, alpha: 1.0),
    NSColor(calibratedRed: 0.99, green: 0.65, blue: 0.30, alpha: 1.0),
    NSColor(calibratedRed: 0.99, green: 0.84, blue: 0.35, alpha: 1.0),
    NSColor(calibratedRed: 0.45, green: 0.82, blue: 0.55, alpha: 1.0),
    NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.75, alpha: 1.0),
    NSColor(calibratedRed: 0.40, green: 0.68, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.68, green: 0.55, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.95, green: 0.55, blue: 0.80, alpha: 1.0),
    NSColor(calibratedRed: 0.90, green: 0.90, blue: 0.94, alpha: 1.0)
]

/// The "apps in a grid" metaphor, generalized to an NxN grid of small
/// rounded squares. `monochromeAlpha`, when set, draws every cell in white
/// at that alpha instead of using `colors` verbatim (for `.monochrome`/
/// `.solid`, which want a single tint rather than a rainbow).
private func drawGrid(ctx: CGContext, size: CGFloat, columns: Int, colors: [NSColor], monochromeAlpha: CGFloat?) {
    let margin = size * 0.20
    let usable = size - margin * 2
    let cellSpacing = usable * 0.10
    let cellSize = (usable - cellSpacing * CGFloat(columns - 1)) / CGFloat(columns)
    let cellCorner = cellSize * 0.28

    for row in 0..<columns {
        for col in 0..<columns {
            let index = row * columns + col
            guard index < colors.count else { continue }
            let x = margin + CGFloat(col) * (cellSize + cellSpacing)
            // Flip row order since CG's origin is bottom-left but the grid
            // should read top-to-bottom the way it's indexed.
            let y = margin + CGFloat(columns - 1 - row) * (cellSize + cellSpacing)
            let cellRect = CGRect(x: x, y: y, width: cellSize, height: cellSize)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -cellSize * 0.04), blur: cellSize * 0.12, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            let cellPath = CGPath(roundedRect: cellRect, cornerWidth: cellCorner, cornerHeight: cellCorner, transform: nil)
            ctx.addPath(cellPath)
            let fillColor = monochromeAlpha.map { colors[index].withAlphaComponent($0) } ?? colors[index]
            ctx.setFillColor(fillColor.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }
}

/// A 5-dot quincunx (four corners + center) — a visually distinct pattern
/// from the NxN grid family, for `.diagonal`.
private func drawQuincunx(ctx: CGContext, size: CGFloat) {
    let margin = size * 0.24
    let usable = size - margin * 2
    let dotSize = usable * 0.28
    let positions: [(CGFloat, CGFloat)] = [
        (0, 1), (1, 1), (0.5, 0.5), (0, 0), (1, 0)
    ]
    for (fx, fy) in positions {
        let x = margin + fx * (usable - dotSize)
        let y = margin + fy * (usable - dotSize)
        let dotRect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -dotSize * 0.04), blur: dotSize * 0.12, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.fillEllipse(in: dotRect)
        ctx.restoreGState()
    }
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    try data.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count > 2, let mode = arguments.dropFirst().first else {
    print("Usage: IconGenerator iconset <output-iconset-dir>")
    print("       IconGenerator variants <output-dir>")
    exit(1)
}
let outputDir = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

switch mode {
case "iconset":
    for spec in iconsetSpecs {
        let image = drawIcon(style: .classic, pixelSize: spec.pixelSize)
        let url = outputDir.appendingPathComponent(spec.fileName)
        try writePNG(image, to: url)
        print("Wrote \(url.path)")
    }
case "variants":
    for style in Style.allCases {
        let image = drawIcon(style: style, pixelSize: 512)
        let url = outputDir.appendingPathComponent("\(style.rawValue).png")
        try writePNG(image, to: url)
        print("Wrote \(url.path)")
    }
default:
    print("Unknown mode '\(mode)' — expected 'iconset' or 'variants'")
    exit(1)
}
