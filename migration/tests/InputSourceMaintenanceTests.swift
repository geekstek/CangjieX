import Foundation

@main
struct InputSourceMaintenanceTests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw InputSourceMaintenance.Failure(message: message) }
    }

    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw InputSourceMaintenance.Failure(message: "Expected refusal: \(message)")
    }

    static func writeApp(_ url: URL, id: String = InputSourceMaintenance.identifier) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleDisplayName": "倉頡星"], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    static func main() throws {
        let m = InputSourceMaintenance.self
        try m.checkSafety(selected: "com.apple.keylayout.ABC", running: [], uid: getuid())
        for id in m.ownedIDs {
            try rejects("active composition/input source") { try m.checkSafety(selected: id, running: [], uid: getuid()) }
        }
        try rejects("root user") { try m.checkSafety(selected: "com.apple.keylayout.ABC", running: [], uid: 0) }
        let settings = m.RunningProcess(pid: 100, uid: getuid(), path: "/System/Applications/System Settings.app/Contents/MacOS/System Settings")
        try rejects("open keyboard settings") { try m.checkSafety(selected: "com.apple.keylayout.ABC", running: [settings], uid: getuid()) }
        try m.checkSafety(selected: "com.apple.keylayout.ABC", running: [.init(pid: 101, uid: getuid() + 1, path: settings.path)], uid: getuid())

        let entries: [[String: Any]] = [
            ["Bundle ID": m.identifier, "InputSourceKind": "Keyboard Input Method"],
            ["Bundle ID": m.obsoleteIdentifier],
            ["Bundle ID": m.legacyIdentifier],
            ["KeyboardLayout Name": "ABC", "KeyboardLayout ID": 252],
            ["Bundle ID": "com.apple.inputmethod.TCIM", "Input Mode": "com.apple.inputmethod.TCIM.Cangjie"],
        ]
        let filtered = m.filteredEntries(entries, removing: m.ownedIDs)
        try check(NSArray(array: filtered).isEqual(to: Array(entries.dropFirst(2))), "Uninstall removed another input source or changed its order")
        try check(m.filteredEntries(filtered, removing: m.ownedIDs).count == 3, "Repeated cleanup is not idempotent")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cjx-maintenance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let app = m.appURL(home: temporary)
        try writeApp(app)
        let legacy = temporary.appendingPathComponent("Library/Input Methods/CangjieX.app")
        try writeApp(legacy, id: m.legacyIdentifier)
        try check(!m.staleIDs(home: temporary, legacySourceExists: false).contains(m.legacyIdentifier), "Existing V1 app treated as stale")
        try check(!m.staleIDs(home: temporary, legacySourceExists: true).contains(m.legacyIdentifier), "Registered V1 source treated as stale")
        let dataFolder = temporary.appendingPathComponent("Library/Application Support/CangjieX Preview")
        try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
        let data: [String: Data] = ["settings.json": Data("{\"synthetic\":true}".utf8), "frequency.json": Data("[]".utf8), "simplex-frequency.json": Data("[]".utf8)]
        for (name, bytes) in data { try bytes.write(to: dataFolder.appendingPathComponent(name)) }
        let receipts = temporary.appendingPathComponent("Library/Receipts")
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        for suffix in ["bom", "plist"] { try Data().write(to: receipts.appendingPathComponent("io.github.geekstek.cangjiex.preview.pkg.\(suffix)")) }
        try m.removeInstalledFiles(home: temporary)

        let purgeHome = temporary.appendingPathComponent("purge-home")
        let purgeApp = m.appURL(home: purgeHome)
        try writeApp(purgeApp)
        let purgeData = purgeHome.appendingPathComponent("Library/Application Support/CangjieX Preview")
        try FileManager.default.createDirectory(at: purgeData, withIntermediateDirectories: true)
        for (name, bytes) in data { try bytes.write(to: purgeData.appendingPathComponent(name)) }
        let outside = temporary.appendingPathComponent("outside-user-data")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("preserve")
        try Data("outside".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: purgeData.appendingPathComponent("linked-data"), withDestinationURL: outside)
        let legacyData = purgeHome.appendingPathComponent("Library/Application Support/Yahoo! KeyKey")
        try FileManager.default.createDirectory(at: legacyData, withIntermediateDirectories: true)
        try m.removeInstalledFiles(home: purgeHome, deleteData: true)
        try check(!FileManager.default.fileExists(atPath: purgeApp.path) && !FileManager.default.fileExists(atPath: purgeData.path), "Complete uninstall kept app or private data")
        try check(try Data(contentsOf: sentinel) == Data("outside".utf8) && FileManager.default.fileExists(atPath: legacyData.path), "Complete uninstall removed linked/legacy data")
        try m.removeInstalledFiles(home: purgeHome, deleteData: true)
        let verification = m.removalVerification(home: purgeHome, deleteData: true, catalogHasSource: true)
        try check(verification.remainingFiles.isEmpty && verification.needsRelogin, "Incomplete cache refresh must be reported honestly")
        try writeApp(purgeApp)
        try FileManager.default.removeItem(at: purgeHome.appendingPathComponent("Library/Application Support"))
        try FileManager.default.createSymbolicLink(at: purgeHome.appendingPathComponent("Library/Application Support"), withDestinationURL: outside)
        try rejects("linked data parent before app deletion") { try m.removeInstalledFiles(home: purgeHome, deleteData: true) }
        try check(FileManager.default.fileExists(atPath: purgeApp.path), "Preflight failure removed app")
        try check(!FileManager.default.fileExists(atPath: app.path), "V2 app not removed")
        try check(try FileManager.default.contentsOfDirectory(atPath: receipts.path).isEmpty, "V2 receipts not removed")
        try check(FileManager.default.fileExists(atPath: legacy.path), "Legacy app removed")
        for (name, bytes) in data { try check(try Data(contentsOf: dataFolder.appendingPathComponent(name)) == bytes, "Settings/learning data changed") }
        try m.removeInstalledFiles(home: temporary)

        try writeApp(app, id: "com.example.unrelated")
        try rejects("unrelated bundle at destination") { try m.removeInstalledFiles(home: temporary) }
        try check(FileManager.default.fileExists(atPath: app.path), "Refusal still removed unrelated bundle")
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: legacy)
        try rejects("linked destination") { try m.removeInstalledFiles(home: temporary) }
        try check(FileManager.default.fileExists(atPath: legacy.path), "Followed a link into legacy app")

        let cache = temporary.appendingPathComponent("cache")
        let panel = cache.appendingPathComponent("com.apple.Keyboard-Settings.extension")
        try FileManager.default.createDirectory(at: panel, withIntermediateDirectories: true)
        let catalog = panel.appendingPathComponent("com.apple.IntlDataCache.le.kbdx")
        let shared = cache.appendingPathComponent("com.apple.IntlDataCache.le.kbdx")
        let other = panel.appendingPathComponent("com.apple.IntlDataCache.le")
        try Data("stale".utf8).write(to: catalog)
        try Data("shared".utf8).write(to: shared)
        try Data("other".utf8).write(to: other)
        try m.clearKeyboardCache(root: cache)
        try check(!FileManager.default.fileExists(atPath: catalog.path), "Stale panel cache remains")
        try check(try Data(contentsOf: shared) == Data("shared".utf8) && Data(contentsOf: other) == Data("other".utf8), "Cache refresh reset unrelated files")
        try m.clearKeyboardCache(root: cache)
        try FileManager.default.createSymbolicLink(at: catalog, withDestinationURL: shared)
        try rejects("linked catalog") { try m.clearKeyboardCache(root: cache) }
        try check(FileManager.default.fileExists(atPath: shared.path), "Cache cleanup followed symlink")
        try FileManager.default.removeItem(at: catalog)
        try m.clearKeyboardCache(root: cache, clearShared: true)
        try check(!FileManager.default.fileExists(atPath: shared.path) && FileManager.default.fileExists(atPath: other.path), "Uninstall did not invalidate only the shared source catalog")
        for id in m.ownedIDs { try FileManager.default.createDirectory(at: cache.appendingPathComponent(id), withIntermediateDirectories: true) }
        let otherCache = cache.appendingPathComponent("com.example.other")
        try FileManager.default.createDirectory(at: otherCache, withIntermediateDirectories: true)
        try m.purgePrivateCaches(root: cache)
        try check(m.ownedIDs.allSatisfy { !FileManager.default.fileExists(atPath: cache.appendingPathComponent($0).path) } && FileManager.default.fileExists(atPath: otherCache.path), "Private cache purge removed another app's cache")
        print("PASS: inactive-source/settings/root guards, targeted preference filtering, safe/idempotent uninstall, receipt removal, settings/learning/legacy preservation, scoped cache refresh and symlink refusal.")
    }
}
