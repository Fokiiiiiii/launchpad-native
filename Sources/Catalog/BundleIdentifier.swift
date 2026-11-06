import CryptoKit
import Foundation

/// `CFBundleIdentifier` is whatever the app's own Info.plist says. It is used
/// to build file paths — an app's data folders, its cached icon, its removal
/// report — so one that carries a slash or a parent-directory component would
/// point those paths somewhere else entirely.
public enum BundleIdentifier {
    /// Whether `value` can be used as one path component, which is all a real
    /// identifier ever is: letters, digits, dots, hyphens and underscores,
    /// starting with a letter or digit.
    public static func isSafeFileName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, !value.contains("..") else { return false }
        guard let first = value.unicodeScalars.first, isAlphanumeric(first) else { return false }
        return value.unicodeScalars.allSatisfy { isAlphanumeric($0) || "._-".unicodeScalars.contains($0) }
    }

    /// `value` when it is safe to use in a file name, otherwise a stand-in that
    /// is, so a hostile identifier still gets a distinct, harmless name.
    public static func fileName(for value: String) -> String {
        guard !isSafeFileName(value) else { return value }
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "invalid-\(digest.prefix(16))"
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x30 && scalar.value <= 0x39)
            || (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }
}
