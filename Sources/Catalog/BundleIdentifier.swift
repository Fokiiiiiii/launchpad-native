import CryptoKit
import Foundation

/// `CFBundleIdentifier` is whatever the app's own Info.plist says. It is used
/// to build file paths — an app's data folders, its cached icon, its removal
/// report — so one that carries a slash or a parent-directory component would
/// point those paths somewhere else entirely.
import CLaunchpadCore
public enum BundleIdentifier {
    /// Whether `value` can be used as one path component, which is all a real
    /// identifier ever is: letters, digits, dots, hyphens and underscores,
    /// starting with a letter or digit.
    public static func isSafeFileName(_ value: String) -> Bool {
        guard value.utf8.count <= 255 else { return false }
        return Array(value.utf8).withUnsafeBufferPointer { bytes in
            launchpad_safe_identifier(bytes.baseAddress, UInt(bytes.count)) != 0
        }
    }

    /// `value` when it is safe to use in a file name, otherwise a stand-in that
    /// is, so a hostile identifier still gets a distinct, harmless name.
    public static func fileName(for value: String) -> String {
        guard !isSafeFileName(value) else { return value }
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "invalid-\(digest.prefix(16))"
    }

}
