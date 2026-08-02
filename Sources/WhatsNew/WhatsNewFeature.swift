import SwiftUI

/// One row's worth of content in the What's New panel. `symbolName` stands
/// in for the reference's own illustrated thumbnails (`WhatsNewRow`'s
/// gradient swatches) — this app's real recent features (folder reordering,
/// gesture-conflict prevention, full-screen folders) don't have pre-made
/// artwork the way the reference's placeholder rows did, and a plain SF
/// Symbol on a tinted rounded square is consistent with how this app
/// already represents features elsewhere (Settings' section headers).
public struct WhatsNewFeature: Identifiable {
    public let id = UUID()
    public let symbolName: String
    public let title: String
    public let body: String

    public init(symbolName: String, title: String, body: String) {
        self.symbolName = symbolName
        self.title = title
        self.body = body
    }
}
