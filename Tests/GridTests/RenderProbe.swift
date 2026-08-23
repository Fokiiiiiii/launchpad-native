import AppKit

/// Renders a live view and reports what actually came out as pixels.
///
/// The layers above this — "the panel exists", "its tiles hold icons" — can all
/// be satisfied by something the user cannot see. This project has shipped a
/// folder snapshot that reported success while producing a fully transparent
/// bitmap, and a folder whose icons were present in the model but drawn as
/// empty placeholders. Looking at pixels is the only check that covers both.
///
/// `cacheDisplay(in:to:)` only yields real pixels for a view that belongs to a
/// window and has been laid out, so callers must host the view first — the same
/// constraint `PageSnapshotRenderer` documents in the production path.
@MainActor
enum RenderProbe {
    static func render(_ view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard view.bounds.width > 1, view.bounds.height > 1,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Fraction of sampled points inside `rect` that are not fully transparent.
    ///
    /// Sampling rather than reading every pixel: a full-screen bitmap is
    /// millions of points, and the questions being asked here ("did anything
    /// draw", "is this region blank") are answered just as well by a grid of
    /// samples.
    static func coverage(_ bitmap: NSBitmapImageRep, in rect: NSRect, samples: Int = 24) -> Double {
        let scaleX = Double(bitmap.pixelsWide) / Double(bitmap.size.width)
        let scaleY = Double(bitmap.pixelsHigh) / Double(bitmap.size.height)
        var opaque = 0
        var total = 0
        for row in 0..<samples {
            for column in 0..<samples {
                let x = rect.minX + rect.width * (Double(column) + 0.5) / Double(samples)
                let y = rect.minY + rect.height * (Double(row) + 0.5) / Double(samples)
                let px = Int((x * scaleX).rounded(.down))
                // AppKit's y runs up; the bitmap's runs down.
                let py = Int(((bitmap.size.height - y) * scaleY).rounded(.down))
                guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh else { continue }
                total += 1
                if let color = bitmap.colorAt(x: px, y: py), color.alphaComponent > 0.05 {
                    opaque += 1
                }
            }
        }
        guard total > 0 else { return 0 }
        return Double(opaque) / Double(total)
    }

    /// How much color variation a region holds. A flat placeholder and a real
    /// app icon both cover their box; only the icon varies across it.
    static func colorVariation(_ bitmap: NSBitmapImageRep, in rect: NSRect, samples: Int = 16) -> Double {
        let scaleX = Double(bitmap.pixelsWide) / Double(bitmap.size.width)
        let scaleY = Double(bitmap.pixelsHigh) / Double(bitmap.size.height)
        var values: [Double] = []
        for row in 0..<samples {
            for column in 0..<samples {
                let x = rect.minX + rect.width * (Double(column) + 0.5) / Double(samples)
                let y = rect.minY + rect.height * (Double(row) + 0.5) / Double(samples)
                let px = Int((x * scaleX).rounded(.down))
                let py = Int(((bitmap.size.height - y) * scaleY).rounded(.down))
                guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh,
                      let color = bitmap.colorAt(x: px, y: py) else { continue }
                values.append(color.brightnessComponent * color.alphaComponent)
            }
        }
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }
}
