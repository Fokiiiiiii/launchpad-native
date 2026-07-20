import Catalog
import Persistence

/// `Catalog.StableAppID` and `Persistence.StableAppIdentifier` are
/// structurally identical (same underlying string) but deliberately distinct
/// types — Catalog and Persistence don't depend on each other (see Phase 2's
/// commit message). `Grid` is the composition layer that depends on both.
///
/// There is intentionally no `StableAppIdentifier -> StableAppID` initializer:
/// `StableAppID` should only ever be constructed from real bundle data by
/// `Catalog`, never round-tripped from a persisted string. Everywhere Grid
/// needs to correlate the two, it compares/keys on the raw `.value` string
/// instead.
extension StableAppID {
    var asPersistenceIdentifier: StableAppIdentifier {
        StableAppIdentifier(value: value)
    }
}
