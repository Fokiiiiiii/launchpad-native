// One-off tool: draws this project's own app icon (never Apple's Launchpad
// artwork — that asset doesn't exist anywhere on a modern macOS install to
// begin with, confirmed by inspecting Dock.app's Assets.car). Original
// composition: a rounded-square (squircle-approximated) gradient tile with
// a 3x3 grid of small colorful rounded squares, evoking "apps arranged in a
// grid" as a generic, non-Apple-owned visual metaphor.
//
// Usage: swift run IconGenerator <output-iconset-dir>
// Then:  iconutil -c icns <output-iconset-dir> -o Resources/AppIcon.icns
import AppKit
import Foundation

struct IconSpec {
    let fileName: String
    let pixelSize: Int
}

let specs: [IconSpec] = [
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

func drawIcon(pixelSize: Int) -> NSImage {
    let size = CGFloat(pixelSize)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.22

    // Background: rounded-square gradient tile (blue -> purple), matching
    // this project's Liquid Glass color language rather than copying any
    // real app's icon.
    let backgroundPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(backgroundPath)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.29, green: 0.40, blue: 0.88, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.54, green: 0.31, blue: 0.88, alpha: 1.0).cgColor
    ]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: size),
            end: CGPoint(x: size, y: 0),
            options: []
        )
    }

    // Soft top highlight — a subtle lighter wash near the top, evoking a
    // glass surface catching light without a hard edge.
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
    ctx.restoreGState()

    // 3x3 grid of small rounded squares — the "apps in a grid" metaphor.
    let gridColors: [NSColor] = [
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

    let margin = size * 0.20
    let usable = size - margin * 2
    let cellSpacing = usable * 0.10
    let cellSize = (usable - cellSpacing * 2) / 3
    let cellCorner = cellSize * 0.28

    for row in 0..<3 {
        for col in 0..<3 {
            let index = row * 3 + col
            let x = margin + CGFloat(col) * (cellSize + cellSpacing)
            // Flip row order since CG's origin is bottom-left but the grid
            // should read top-to-bottom the way it's indexed.
            let y = margin + CGFloat(2 - row) * (cellSize + cellSpacing)
            let cellRect = CGRect(x: x, y: y, width: cellSize, height: cellSize)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -cellSize * 0.04), blur: cellSize * 0.12, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            let cellPath = CGPath(roundedRect: cellRect, cornerWidth: cellCorner, cornerHeight: cellCorner, transform: nil)
            ctx.addPath(cellPath)
            ctx.setFillColor(gridColors[index].cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
        throw NSError(domain: "IconGenerator", code: 1)
    }
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 2)
    }
    try data.write(to: url)
}

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("Usage: IconGenerator <output-iconset-dir>")
    exit(1)
}
let outputDir = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for spec in specs {
    let image = drawIcon(pixelSize: spec.pixelSize)
    let url = outputDir.appendingPathComponent(spec.fileName)
    try writePNG(image, to: url, pixelSize: spec.pixelSize)
    print("Wrote \(url.path)")
}
