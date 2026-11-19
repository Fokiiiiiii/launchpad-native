import Catalog
import Foundation
import Testing
@testable import Uninstall

/// Exercises `OwnershipEvidenceCollector` against real files under a
/// temporary `~/Library`-shaped directory tree, so evidence collection is
/// proven against the actual filesystem APIs (not just hand-built
/// `OwnershipEvidence` values, which `RemovalPlannerTests` already covers).
///
/// This does NOT touch the real `~/Library` — `OwnershipEvidenceCollector`
/// itself always reads from the real home directory, so this suite instead
/// verifies the piece that's independent of that: the pure `RelatedPath`
/// existence check and receipt/extension parsing, using real bundles it
/// creates and deletes itself.
import Darwin

@Suite("OwnershipEvidenceCollector")
struct OwnershipEvidenceCollectorTests {
    @Test("a launch item's name has to be the identifier or a dotted child of it")
    func launchItemNamesRespectTheBoundary() {
        #expect(OwnershipEvidenceCollector.isOwnName("com.example.app", bundleID: "com.example.app"))
        #expect(OwnershipEvidenceCollector.isOwnName("com.example.app.helper", bundleID: "com.example.app"))
        #expect(!OwnershipEvidenceCollector.isOwnName("com.example.app2", bundleID: "com.example.app"))
        #expect(!OwnershipEvidenceCollector.isOwnName("com.example.appstore.helper", bundleID: "com.example.app"))
        #expect(!OwnershipEvidenceCollector.isOwnName("com.example", bundleID: "com.example.app"))
    }

    private func writeAgent(named name: String, label: String?, in directory: URL) throws {
        var plist: [String: Any] = ["ProgramArguments": ["/usr/bin/true"]]
        if let label { plist["Label"] = label }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent(name))
    }

    /// The Label is what gets unloaded from launchd before the file is trashed,
    /// so a file named like this app's but labelled as another product's job
    /// must not be taken.
    @Test("a user LaunchAgent is taken only when its name and its Label both belong to the app")
    func launchAgentsNeedANameAndALabelThatAgree() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAgent(named: "com.example.app.plist", label: "com.example.app", in: dir)
        try writeAgent(named: "com.example.app.helper.plist", label: "com.example.app.helper", in: dir)
        try writeAgent(named: "com.example.app2.plist", label: "com.example.app2", in: dir)
        try writeAgent(named: "com.example.app.imposter.plist", label: "com.other.product.job", in: dir)
        try writeAgent(named: "com.example.app.nolabel.plist", label: nil, in: dir)

        let taken = OwnershipEvidenceCollector
            .launchItems(in: dir, matchingBundleID: "com.example.app", verifyingLabel: true)
            .map(\.lastPathComponent)
            .sorted()

        #expect(taken == ["com.example.app.helper.plist", "com.example.app.plist"])
    }

    @Test("without Label checking a name that fits is enough")
    func launchItemsWithoutLabelChecking() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeAgent(named: "com.example.app.plist", label: "anything", in: dir)
        try writeAgent(named: "com.example.apple.plist", label: "anything", in: dir)

        let taken = OwnershipEvidenceCollector
            .launchItems(in: dir, matchingBundleID: "com.example.app", verifyingLabel: false)
            .map(\.lastPathComponent)

        #expect(taken == ["com.example.app.plist"])
    }

    @Test("receipt output keeps Swift line and Unicode matching semantics")
    func receiptsMatchSwiftSplitAndRejectInvalidUTF8() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("fixture")
        func install(_ script: String) throws {
            try Data(script.utf8).write(to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        }
        let text = "org.example.app.one\nother\r\norg.example.app.two\n\norg.example.app.last"
        try install("#!/bin/sh\n/usr/bin/printf 'org.example.app.one\\nother\\r\\norg.example.app.two\\n\\norg.example.app.last'\n/usr/bin/head -c 262144 /dev/zero >&2\nexit 4\n")
        let expected = text.split(separator: "\n").map(String.init).filter { $0.contains("org.example.app") }
        #expect(OwnershipEvidenceCollector.receipts(matchingBundleID: "org.example.app", program: program.path) == expected)

        try install("#!/bin/sh\n/usr/bin/printf 'org.cafe\\314\\201.app\\n'\n")
        #expect(OwnershipEvidenceCollector.receipts(matchingBundleID: "org.café.app", program: program.path) == ["org.cafe\u{301}.app"])

        try install("#!/bin/sh\n/usr/bin/printf 'org.example.app.one\\n\\377'\n")
        #expect(OwnershipEvidenceCollector.receipts(matchingBundleID: "org.example.app", program: program.path).isEmpty)
        #expect(OwnershipEvidenceCollector.receipts(matchingBundleID: "org.example.app", program: root.appendingPathComponent("missing").path).isEmpty)
    }

    @Test func benchmarkReceiptSelectionMemory() throws {
        guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let program = root.appendingPathComponent("fixture")
        let script = "#!/bin/sh\n/usr/bin/yes 'org.other.long.packagename.fixture.example.1234567890' | /usr/bin/head -n 50000\n/usr/bin/printf 'org.example.target\\n'\n"
        try Data(script.utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let useRust = ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_MODE"] == "receipt-rust"
        func peak() -> Int {
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            return usage.ru_maxrss
        }
        let baseline = peak()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<3 {
            let items: [String]
            if useRust {
                items = OwnershipEvidenceCollector.receipts(matchingBundleID: "org.example.target", program: program.path)
            } else {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = program
                process.arguments = ["--pkgs"]
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = try #require(String(data: output, encoding: .utf8))
                items = text.split(separator: "\n").map(String.init).filter { $0.contains("org.example.target") }
            }
            #expect(items == ["org.example.target"])
        }
        print("MEMORY_BENCH scenario=receipt-\(useRust ? "rust" : "swift") items=50001 baseline_bytes=\(baseline) peak_bytes=\(peak()) elapsed_ns=\(DispatchTime.now().uptimeNanoseconds - start)")
    }

    @Test("streamed directory selection agrees with Foundation")
    func directorySelectionMatchesFoundation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["com.example.app", ".com.example.app.hidden", "com.example.app.é", "com.example.app.日本語", "com.example.app.%#?", "com.example.other"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let subdirectory = root.appendingPathComponent("com.example.app.folder", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("com.example.app.link"), withDestinationURL: subdirectory)
        let filter: (String) -> Bool = { $0.contains("com.example.app") }
        let expected = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { filter($0.lastPathComponent) }
        let actual = OwnershipEvidenceCollector.directoryEntries(in: root, matching: filter)
        #expect(Set(actual.map(\.path)) == Set(expected.map(\.path)))
        try Data().write(to: subdirectory.appendingPathComponent("entry"))
        let link = root.appendingPathComponent("com.example.app.link")
        let linkedExpected = (try? FileManager.default.contentsOfDirectory(at: link, includingPropertiesForKeys: nil)) ?? []
        let linkedActual = OwnershipEvidenceCollector.directoryEntries(in: link) { _ in true }
        #expect(Set(linkedActual.map(\.path)) == Set(linkedExpected.map(\.path)))
        #expect(OwnershipEvidenceCollector.directoryEntries(in: root.appendingPathComponent("missing"), matching: filter).isEmpty)
    }

    @Test func benchmarkDirectorySelectionMemory() throws {
        guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<4096 {
            let name = index.isMultiple(of: 128) ? "com.example.app.\(index)" : "other.\(index)"
            #expect(FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: nil))
        }
        let useRust = ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_MODE"] == "directory-rust"
        let filter: (String) -> Bool = { $0.hasPrefix("com.example.app.") }
        func peak() -> Int {
            var usage = rusage()
            _ = getrusage(RUSAGE_SELF, &usage)
            return usage.ru_maxrss
        }
        let baseline = peak()
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 {
            let items = useRust
                ? OwnershipEvidenceCollector.directoryEntries(in: root, matching: filter)
                : try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { filter($0.lastPathComponent) }
            #expect(items.count == 32)
        }
        print("MEMORY_BENCH scenario=directory-\(useRust ? "rust" : "swift") items=4096 baseline_bytes=\(baseline) peak_bytes=\(peak()) elapsed_ns=\(DispatchTime.now().uptimeNanoseconds - start)")
    }

    /// An identifier is text from the app's own Info.plist. If it climbed out
    /// of ~/Library, the plan would pre-check, say, the user's Documents.
    @Test("an identifier that is not a plain file name produces no related paths at all")
    func hostileIdentifierGivesNoRelatedPaths() {
        for hostile in ["../../Documents", "a/b", "com.example/../..", ".hidden", "", "x\u{0}y"] {
            let url = URL(fileURLWithPath: "/tmp/Hostile.app")
            let record = ApplicationRecord(
                id: StableAppID(bundleURL: url, bundleIdentifier: hostile, teamIdentifier: nil),
                bundleIdentifier: hostile,
                bundleURL: url,
                executableURL: nil,
                displayName: "Hostile",
                originalDisplayName: "Hostile",
                bundleVersion: "1.0",
                teamIdentifier: nil,
                category: nil,
                sourceID: "test",
                isSystemProtected: false,
                isBackgroundOnly: false,
                iconCacheKey: "hostile",
                canLaunch: false,
                canOpenNewInstance: false,
                lastSeenModificationDate: Date()
            )

            let evidence = OwnershipEvidenceCollector.collect(for: record)

            #expect(evidence.relatedPaths.isEmpty, "\(hostile.debugDescription)")
            #expect(evidence.userLaunchAgents.isEmpty)
            #expect(evidence.systemLaunchItems.isEmpty)
            #expect(evidence.receiptPackageIDs.isEmpty)
        }
    }

    @Test("a bundle with NSExtension in its Info.plist is reported")
    func extensionDeclarationDetected() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = "com.example.withextension"
        let bundleURL = tempDir.appendingPathComponent("WithExtension.app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "WithExtension",
            "CFBundlePackageType": "APPL",
            "NSExtension": ["NSExtensionPointIdentifier": "com.example.point"]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let record = ApplicationRecord(
            id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleID, teamIdentifier: nil),
            bundleIdentifier: bundleID,
            bundleURL: bundleURL,
            executableURL: nil,
            displayName: "WithExtension",
            originalDisplayName: "WithExtension",
            bundleVersion: "1.0",
            teamIdentifier: nil,
            category: nil,
            sourceID: "test",
            isSystemProtected: false,
            isBackgroundOnly: false,
            iconCacheKey: bundleID,
            canLaunch: false,
            canOpenNewInstance: false,
            lastSeenModificationDate: Date()
        )

        let evidence = OwnershipEvidenceCollector.collect(for: record)
        #expect(evidence.systemExtensionIdentifiers == [bundleID])
    }

    @Test("a bundle with no NSExtension declaration reports none")
    func noExtensionDeclaration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleID = "com.example.plain"
        let bundleURL = tempDir.appendingPathComponent("Plain.app")
        let contentsURL = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Plain",
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let record = ApplicationRecord(
            id: StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleID, teamIdentifier: nil),
            bundleIdentifier: bundleID,
            bundleURL: bundleURL,
            executableURL: nil,
            displayName: "Plain",
            originalDisplayName: "Plain",
            bundleVersion: "1.0",
            teamIdentifier: nil,
            category: nil,
            sourceID: "test",
            isSystemProtected: false,
            isBackgroundOnly: false,
            iconCacheKey: bundleID,
            canLaunch: false,
            canOpenNewInstance: false,
            lastSeenModificationDate: Date()
        )

        let evidence = OwnershipEvidenceCollector.collect(for: record)
        #expect(evidence.systemExtensionIdentifiers.isEmpty)
    }

    /// Real files under the real home directory, using a bundle identifier
    /// exclusive to this test run — `OwnershipEvidenceCollector` always
    /// reads the real `~/Library`, so proving the newer categories
    /// (Containers, Group Containers, Saved Application State, WebKit,
    /// HTTPStorages, Cookies, Logs, Application Scripts, ByHost prefs) work
    /// means creating and then cleaning up real files there, same as the
    /// fixture script does for manual verification.
    @Test("newer related-path categories are detected under the real home directory")
    func newerCategoriesDetected() throws {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = "com.launchpadnative.uninstalltests.\(UUID().uuidString)"

        let container = home.appendingPathComponent("Library/Containers/\(bundleID)")
        let groupContainer = home.appendingPathComponent("Library/Group Containers/group.\(bundleID)")
        let savedState = home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState")
        let webKit = home.appendingPathComponent("Library/WebKit/\(bundleID)")
        let httpStorages = home.appendingPathComponent("Library/HTTPStorages/\(bundleID)")
        let cookies = home.appendingPathComponent("Library/Cookies/\(bundleID).binarycookies")
        let logs = home.appendingPathComponent("Library/Logs/\(bundleID)")
        let appScripts = home.appendingPathComponent("Library/Application Scripts/\(bundleID)")
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost/\(bundleID).0123ABCD.plist")

        let directories = [container, groupContainer, savedState, webKit, httpStorages, logs, appScripts]
        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: cookies.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: cookies)
        try fm.createDirectory(at: byHost.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: byHost)

        defer {
            for directory in directories { try? fm.removeItem(at: directory) }
            try? fm.removeItem(at: cookies)
            try? fm.removeItem(at: byHost)
        }

        let record = ApplicationRecord(
            id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(bundleID).app"), bundleIdentifier: bundleID, teamIdentifier: nil),
            bundleIdentifier: bundleID,
            bundleURL: URL(fileURLWithPath: "/tmp/\(bundleID).app"),
            executableURL: nil,
            displayName: bundleID,
            originalDisplayName: bundleID,
            bundleVersion: "1.0",
            teamIdentifier: nil,
            category: nil,
            sourceID: "test",
            isSystemProtected: false,
            isBackgroundOnly: false,
            iconCacheKey: bundleID,
            canLaunch: false,
            canOpenNewInstance: false,
            lastSeenModificationDate: Date()
        )

        let evidence = OwnershipEvidenceCollector.collect(for: record)
        let categories = Set(evidence.relatedPaths.filter(\.exists).map(\.category))

        #expect(categories.contains(.containers))
        #expect(categories.contains(.groupContainers))
        #expect(categories.contains(.savedApplicationState))
        #expect(categories.contains(.webKit))
        #expect(categories.contains(.httpStorages))
        #expect(categories.contains(.cookies))
        #expect(categories.contains(.logs))
        #expect(categories.contains(.applicationScripts))
        #expect(categories.contains(.preferencesByHost))
    }
}
