// Phase 2 manual verification: scans the real standard sources on this
// machine and reports timing + a sample, satisfying "実機アプリを列挙."
import Catalog
import Foundation

let scanner = ApplicationScanner()
let start = DispatchTime.now()
let snapshot = await scanner.performFullScan()
let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

print("Scanned \(snapshot.records.count) applications in \(String(format: "%.1f", elapsedMs))ms")
print("")

let bySource = Dictionary(grouping: snapshot.records, by: \.sourceID)
for (sourceID, records) in bySource.sorted(by: { $0.key < $1.key }) {
    print("  \(sourceID): \(records.count)")
}

print("")
print("Sample (first 5, sorted by display name):")
for record in snapshot.records.sorted(by: { $0.displayName < $1.displayName }).prefix(5) {
    print("  \(record.displayName)  [\(record.bundleIdentifier)]  backgroundOnly=\(record.isBackgroundOnly)  system=\(record.isSystemProtected)")
}

let duplicateBundleIDs = Dictionary(grouping: snapshot.records, by: \.bundleIdentifier)
    .filter { $0.value.count > 1 }
if !duplicateBundleIDs.isEmpty {
    print("")
    print("Duplicate bundle identifiers (distinct stable IDs expected):")
    for (bundleID, records) in duplicateBundleIDs {
        print("  \(bundleID): \(records.count) locations")
    }
}
