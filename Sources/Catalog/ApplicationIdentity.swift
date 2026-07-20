import CryptoKit
import Foundation
import Security

/// A stable identity for one installed `.app`, derived from data that
/// survives relaunches and Finder moves within the same volume: the volume's
/// own UUID, the bundle's normalized path, its bundle identifier, and its
/// code-signing team identifier when present. Two apps with the same bundle
/// identifier at different paths (or on different volumes) get distinct IDs,
/// satisfying the "identify duplicate bundle ID placements" requirement.
public struct StableAppID: Hashable, Codable, Sendable {
    public let value: String

    init(bundleURL: URL, bundleIdentifier: String, teamIdentifier: String?) {
        let volumeUUID = (try? bundleURL.resourceValues(forKeys: [.volumeUUIDStringKey]))?
            .volumeUUIDString ?? "unknown-volume"
        let normalizedPath = bundleURL.standardizedFileURL.path
        let raw = "\(bundleIdentifier)|\(volumeUUID)|\(normalizedPath)|\(teamIdentifier ?? "unsigned")"
        let digest = SHA256.hash(data: Data(raw.utf8))
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Reads code-signing team identifier via the public Security framework
/// (`SecStaticCode`), not a private API — deliberately avoiding any
/// LaunchServices SPI dependency for something the public API already covers.
enum CodeSigningInspector {
    static func teamIdentifier(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else { return nil }

        var information: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard infoStatus == errSecSuccess,
              let dict = information as? [String: Any] else { return nil }
        return dict["teamid"] as? String
    }
}
