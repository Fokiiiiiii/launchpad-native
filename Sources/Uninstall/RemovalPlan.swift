import Catalog
import Foundation

/// How confident the planner is that a path/registration belongs
/// exclusively to the app being uninstalled.
public enum OwnershipClassification: Sendable, Equatable {
    /// Only ever observed to belong to this app — safe to offer as an
    /// automatic removal candidate.
    case owned
    /// Plausibly shared with another installed app (same code-signing team,
    /// or another app's own data nested underneath) — never auto-remove,
    /// always require an explicit per-item confirmation.
    case sharedRisk
    /// Could not be attributed with confidence. Never offered for removal,
    /// automatic or otherwise.
    case unknown
}

/// One candidate for removal, always paired with the confidence level that
/// gates whether (and how) it may ever be acted on.
public struct RemovalItem: Sendable, Equatable {
    public let path: URL
    public let classification: OwnershipClassification
    /// True when the path/registration lives outside the user's own
    /// domain (e.g. `/Library/LaunchDaemons`) or is otherwise root-owned —
    /// removal would need a Privileged Helper, which this phase does not
    /// implement yet.
    public let requiresPrivilegedHelper: Bool

    public init(path: URL, classification: OwnershipClassification, requiresPrivilegedHelper: Bool) {
        self.path = path
        self.classification = classification
        self.requiresPrivilegedHelper = requiresPrivilegedHelper
    }
}

/// Turns `OwnershipEvidence` into a list of classified removal candidates.
/// Pure function, no I/O of its own beyond what `siblingRecords`/`evidence`
/// already observed — never deletes, moves, or executes anything.
public enum RemovalPlanner {
    /// - Parameters:
    ///   - record: the app being planned for removal.
    ///   - evidence: everything `OwnershipEvidenceCollector` found for it.
    ///   - siblingRecords: every other currently-installed app, used to
    ///     detect paths that are plausibly shared (same code-signing team,
    ///     or another app's own data nested underneath this one's).
    public static func plan(
        for record: ApplicationRecord,
        evidence: OwnershipEvidence,
        siblingRecords: [ApplicationRecord] = []
    ) -> [RemovalItem] {
        // System-protected apps (bundled with the OS) are never removal
        // candidates at all — the whole plan collapses to a single
        // `.unknown` entry for the bundle itself rather than enumerating
        // paths that must not be touched.
        guard !record.isSystemProtected else {
            return [RemovalItem(path: record.bundleURL, classification: .unknown, requiresPrivilegedHelper: false)]
        }

        var items: [RemovalItem] = []

        for related in evidence.relatedPaths where related.exists {
            let classification = classify(related, record: record, siblingRecords: siblingRecords)
            items.append(RemovalItem(path: related.url, classification: classification, requiresPrivilegedHelper: false))
        }

        for agent in evidence.userLaunchAgents {
            items.append(RemovalItem(path: agent, classification: .owned, requiresPrivilegedHelper: false))
        }

        for systemItem in evidence.systemLaunchItems {
            items.append(RemovalItem(path: systemItem, classification: .sharedRisk, requiresPrivilegedHelper: true))
        }

        for receiptID in evidence.receiptPackageIDs {
            // A package receipt affects `pkgutil`'s own bookkeeping, not
            // just files on disk — never a confident automatic candidate.
            items.append(RemovalItem(
                path: URL(fileURLWithPath: "/var/db/receipts/\(receiptID)"),
                classification: .unknown,
                requiresPrivilegedHelper: true
            ))
        }

        return items
    }

    /// A path is `.sharedRisk` if either:
    /// - it's a Group Container — shared *by design* across every app in
    ///   the group, regardless of whether a sibling with a matching
    ///   code-signing team is even currently installed, or
    /// - another installed app with the same code-signing team (but a
    ///   different bundle identifier) has its own data nested underneath it
    ///   — deleting the parent would take the sibling's data with it.
    /// Otherwise, since evidence collection only ever returns paths keyed by
    /// this app's own bundle identifier, anything that exists is `.owned`.
    private static func classify(
        _ related: RelatedPath,
        record: ApplicationRecord,
        siblingRecords: [ApplicationRecord]
    ) -> OwnershipClassification {
        if case .groupContainers = related.category { return .sharedRisk }
        let path = related.url

        guard let teamIdentifier = record.teamIdentifier else { return .owned }

        let siblingsSharingTeam = siblingRecords.filter {
            $0.bundleIdentifier != record.bundleIdentifier && $0.teamIdentifier == teamIdentifier
        }
        guard !siblingsSharingTeam.isEmpty else { return .owned }

        let fm = FileManager.default
        for sibling in siblingsSharingTeam {
            let nestedCandidate = path.appendingPathComponent(sibling.bundleIdentifier)
            if fm.fileExists(atPath: nestedCandidate.path) {
                return .sharedRisk
            }
        }
        return .owned
    }
}
