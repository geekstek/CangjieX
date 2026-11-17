import Foundation
import Carbon
import CoreServices

enum InputSourceMaintenance {
    static let identifier = "io.github.geekstek.inputmethod.CangjieXPreview"
    static let obsoleteIdentifier = "io.github.geekstek.inputmethod.CangjieX.Preview"
    static let legacyIdentifier = "io.github.geekstek.inputmethod.CangjieX"
    static let ownedIDs: Set<String> = [identifier, obsoleteIdentifier]
    static let registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    static let keyboardPanel = "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex/Contents/MacOS/KeyboardSettings"
    static let menuAgent = "/System/Library/CoreServices/TextInputMenuAgent.app/Contents/MacOS/TextInputMenuAgent"

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct RunningProcess {
        let pid: Int32
        let uid: UInt32
        let path: String
    }

    static func appURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Input Methods/CangjieXPreview.app")
    }

    static func validateApp(_ app: URL) throws {
        // Never follow a replacement link into another app or another user's files.
        for url in [app.deletingLastPathComponent(), app, app.appendingPathComponent("Contents")] {
            guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false else {
                throw Failure(message: "拒絕處理符號連結：\(url.path)")
            }
        }
        let info = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
        guard plist?["CFBundleIdentifier"] as? String == identifier,
              plist?["CFBundleDisplayName"] as? String == "倉頡星" else {
            throw Failure(message: "程式識別或名稱不符，停止維護；請先安裝新版倉頡星。")
        }
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = pipe
        try task.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw Failure(message: "維護指令失敗：\(URL(fileURLWithPath: executable).lastPathComponent)（\(task.terminationStatus)）")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func processes() throws -> [RunningProcess] {
        try run("/bin/ps", ["-axo", "pid=,uid=,comm="]).split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            guard fields.count == 3, let pid = Int32(fields[0]), let uid = UInt32(fields[1]) else { return nil }
            return RunningProcess(pid: pid, uid: uid, path: String(fields[2]))
        }
    }

    static func sourceProperty(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    }

    static func sources(_ id: String) -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true) else { return [] }
        return list.takeRetainedValue() as! [TISInputSource]
    }

    static func checkSafety(selected: String, running: [RunningProcess], uid: UInt32) throws {
        try checkEnvironment(running: running, uid: uid)
        guard !ownedIDs.contains(selected) else {
            throw Failure(message: "請先完成組字並切換到 ABC，再執行維護，避免遺失正在輸入的文字。")
        }
    }

    static func checkEnvironment(running: [RunningProcess], uid: UInt32) throws {
        guard uid != 0 else { throw Failure(message: "請以目前登入的使用者執行，不要使用 sudo。") }
        let settingsPaths: Set<String> = ["/System/Applications/System Settings.app/Contents/MacOS/System Settings",
                                          "/System/Applications/System Preferences.app/Contents/MacOS/System Preferences"]
        guard !running.contains(where: { $0.uid == uid && settingsPaths.contains($0.path) }) else {
            throw Failure(message: "請先結束「系統設定」（Command＋Q），再執行維護。")
        }
    }

    static func selectABC() throws {
        guard let abc = sources("com.apple.keylayout.ABC").first,
              (sourceProperty(abc, kTISPropertyInputSourceIsEnabled) as? NSNumber)?.boolValue == true,
              TISSelectInputSource(abc) == noErr else {
            throw Failure(message: "無法自動切換到 ABC。請先手動切換到 ABC，再重新解除安裝；尚未刪除任何檔案。")
        }
    }

    static func preflight() throws {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let selected = sourceProperty(current, kTISPropertyInputSourceID) as? String ?? ""
        guard !selected.isEmpty else { throw Failure(message: "無法確認目前輸入源，停止維護。") }
        try checkSafety(selected: selected, running: processes(), uid: getuid())
    }

    static func filteredEntries(_ entries: [[String: Any]], removing ids: Set<String>) -> [[String: Any]] {
        entries.filter { !ids.contains($0["Bundle ID"] as? String ?? "") }
    }

    static func staleIDs(home: URL, legacySourceExists: Bool) -> Set<String> {
        var ids: Set<String> = [obsoleteIdentifier]
        let paths = [home.appendingPathComponent("Library/Input Methods/CangjieX.app"),
                     URL(fileURLWithPath: "/Library/Input Methods/CangjieX.app")]
        if !legacySourceExists && paths.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) {
            ids.insert(legacyIdentifier)
        }
        return ids
    }

    static func cleanPreferences(removing ids: Set<String>) throws {
        let domains = ["com.apple.inputsources": ["AppleEnabledThirdPartyInputSources"],
                       "com.apple.HIToolbox": ["AppleEnabledInputSources", "AppleSelectedInputSources", "AppleInputSourceHistory"]]
        for (domain, keys) in domains {
            var changed = false
            for key in keys {
                guard let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString) else { continue }
                guard let entries = value as? [[String: Any]] else {
                    throw Failure(message: "輸入源記錄格式不符，未覆寫：\(domain)/\(key)")
                }
                let filtered = filteredEntries(entries, removing: ids)
                if filtered.count != entries.count {
                    CFPreferencesSetAppValue(key as CFString, filtered as CFArray, domain as CFString)
                    changed = true
                }
            }
            if changed && !CFPreferencesAppSynchronize(domain as CFString) {
                throw Failure(message: "無法保存輸入源記錄：\(domain)")
            }
        }
    }

    static func stop(_ paths: Set<String>) throws {
        for process in try processes() where process.uid == getuid() && process.pid != getpid() && paths.contains(process.path) {
            guard kill(process.pid, SIGTERM) == 0 || errno == ESRCH else {
                throw Failure(message: "無法結束維護相關程序：\(URL(fileURLWithPath: process.path).lastPathComponent)")
            }
            for _ in 0..<40 {
                if kill(process.pid, 0) != 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            guard kill(process.pid, 0) != 0 else {
                throw Failure(message: "背景程序仍在使用舊資料，請登出並重新登入後再試。")
            }
        }
    }

    static func unregisterCopies(except installed: URL?, ids: Set<String> = ownedIDs) throws {
        for id in ids {
            guard let values = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() as? [URL] else { continue }
            for url in Set(values) where url.standardizedFileURL != installed?.standardizedFileURL {
                _ = try run(registrar, ["-u", url.path])
            }
        }
    }

    static func clearKeyboardCache(root: URL, clearShared: Bool = false) throws {
        // This panel keeps its own catalog even after TIS and the menu are refreshed.
        let folder = root.appendingPathComponent("com.apple.Keyboard-Settings.extension")
        let file = folder.appendingPathComponent("com.apple.IntlDataCache.le.kbdx")
        var targets = [(folder, file)]
        if clearShared { targets.append((root, root.appendingPathComponent("com.apple.IntlDataCache.le.kbdx"))) }
        for (parent, target) in targets where FileManager.default.fileExists(atPath: target.path) {
            for url in [parent, target] {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                    throw Failure(message: "快取擁有者或路徑不符，未刪除：\(url.path)")
                }
            }
            try FileManager.default.removeItem(at: target)
        }
    }

    static func refreshCatalog(clearShared: Bool) throws {
        try stop([keyboardPanel])
        try clearKeyboardCache(root: privateCacheRoot(), clearShared: clearShared)
        try stop([menuAgent])
    }

    static func privateCacheRoot() throws -> URL {
        let path = try run("/usr/bin/getconf", ["DARWIN_USER_CACHE_DIR"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/var/folders/") || path.hasPrefix("/private/var/folders/") else {
            throw Failure(message: "無法確認使用者快取目錄，請登出並重新登入以刷新清單。")
        }
        return URL(fileURLWithPath: path)
    }

    static func purgePrivateCaches(root: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw Failure(message: "使用者快取目錄不符，未刪除。")
        }
        for id in ownedIDs {
            let path = root.appendingPathComponent(id)
            if (try? FileManager.default.attributesOfItem(atPath: path.path)) != nil { try FileManager.default.removeItem(at: path) }
        }
    }

    static func dataPaths(home: URL) -> [URL] {
        var paths = [home.appendingPathComponent("Library/Application Support/CangjieX Preview")]
        for id in ownedIDs.sorted() {
            for suffix in ["Preferences/\(id).plist", "Caches/\(id)", "Logs/\(id)", "Saved Application State/\(id).savedState"] {
                paths.append(home.appendingPathComponent("Library/\(suffix)"))
            }
            let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
            if let files = try? FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil) {
                paths += files.filter { $0.lastPathComponent.hasPrefix(id + ".") && $0.pathExtension == "plist" }
            }
        }
        return paths
    }

    static func validateParents(of target: URL, home: URL) throws {
        var parent = target.deletingLastPathComponent().standardizedFileURL
        let root = home.standardizedFileURL
        guard parent.path.hasPrefix(root.path + "/") else { throw Failure(message: "拒絕刪除使用者目錄以外的資料。") }
        while parent != root {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw Failure(message: "資料目錄包含符號連結，未刪除：\(parent.path)")
            }
            parent.deleteLastPathComponent()
        }
    }

    static func purgeUserData(home: URL) throws {
        let targets = dataPaths(home: home)
        for target in targets { try validateParents(of: target, home: home) }
        for target in targets {
            if (try? FileManager.default.attributesOfItem(atPath: target.path)) != nil {
                try FileManager.default.removeItem(at: target)
            }
        }
    }

    static func removeInstalledFiles(home: URL, deleteData: Bool = false) throws {
        let app = appURL(home: home)
        if deleteData {
            for target in dataPaths(home: home) { try validateParents(of: target, home: home) }
        }
        if FileManager.default.fileExists(atPath: app.path) {
            try validateApp(app)
            try FileManager.default.removeItem(at: app)
        }
        for suffix in ["bom", "plist"] {
            let receipt = home.appendingPathComponent("Library/Receipts/io.github.geekstek.cangjiex.preview.pkg.\(suffix)")
            if FileManager.default.fileExists(atPath: receipt.path) { try FileManager.default.removeItem(at: receipt) }
        }
        if deleteData { try purgeUserData(home: home) }
    }

    struct RemovalVerification: Codable {
        let remainingFiles: [String]
        let remainingPreferenceEntries: Bool
        let needsRelogin: Bool
    }

    static func removalVerification(home: URL, deleteData: Bool, catalogHasSource: Bool, cacheRoot: URL? = nil) -> RemovalVerification {
        var paths = [appURL(home: home)]
        paths += ["bom", "plist"].map { home.appendingPathComponent("Library/Receipts/io.github.geekstek.cangjiex.preview.pkg.\($0)") }
        if deleteData {
            paths += dataPaths(home: home)
            if let cacheRoot { paths += ownedIDs.map { cacheRoot.appendingPathComponent($0) } }
        }
        let remaining = paths.filter { (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil }.map(\.path)
        let keys = ["com.apple.inputsources": ["AppleEnabledThirdPartyInputSources"],
                    "com.apple.HIToolbox": ["AppleEnabledInputSources", "AppleSelectedInputSources", "AppleInputSourceHistory"]]
        let entriesRemain = keys.contains { domain, keys in keys.contains { key in
            guard let entries = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? [[String: Any]] else { return false }
            return filteredEntries(entries, removing: ownedIDs).count != entries.count
        } }
        return RemovalVerification(remainingFiles: remaining, remainingPreferenceEntries: entriesRemain, needsRelogin: catalogHasSource)
    }

    static func execute(_ command: String, deleteData: Bool = false) throws {
        guard !deleteData || ["uninstall", "verify-uninstall"].contains(command) else {
            throw Failure(message: "--delete-data 只能搭配 uninstall 使用。")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let app = appURL(home: home)
        switch command {
        case "verify-uninstall":
            let report = removalVerification(home: home, deleteData: deleteData, catalogHasSource: ownedIDs.contains { !sources($0).isEmpty }, cacheRoot: deleteData ? try privateCacheRoot() : nil)
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        case "status":
            try validateApp(app)
            print("已安裝：\(app.path)")
            for source in sources(identifier) {
                let name = sourceProperty(source, kTISPropertyLocalizedName) as? String ?? "（空白）"
                print("系統輸入源名稱：\(name)")
            }
            print("畫面驗證：請檢查已加入清單、繁體中文可加入清單及右上角選單；API 名稱正確不代表三處快取已更新。")
        case "check":
            try preflight()
        case "repair", "uninstall":
            try preflight()
            if FileManager.default.fileExists(atPath: app.path) { try validateApp(app) }
            else if command == "repair" { throw Failure(message: "尚未安裝倉頡星，請先執行安裝包。") }
            if command == "repair" {
                try stop([app.appendingPathComponent("Contents/MacOS/CangjieXPreview").path])
                try unregisterCopies(except: app)
                _ = try run(registrar, ["-f", app.path])
                let status = TISRegisterInputSource(app as CFURL)
                guard status == noErr else { throw Failure(message: "輸入源註冊失敗（\(status)）。") }
                for source in sources(obsoleteIdentifier) {
                    guard TISDisableInputSource(source) == noErr else {
                        throw Failure(message: "無法停用舊 Preview 記錄，請登出並重新登入後再試。")
                    }
                }
            } else {
                for id in ownedIDs {
                    for source in sources(id) {
                        let status = TISDisableInputSource(source)
                        guard status == noErr else { throw Failure(message: "無法停用輸入源（\(status)），未刪除程式。") }
                    }
                }
                try unregisterCopies(except: nil)
                try stop([app.appendingPathComponent("Contents/MacOS/CangjieXPreview").path])
                try removeInstalledFiles(home: home, deleteData: deleteData)
            }
            // Prune V1 references only when neither its app nor its TIS source exists.
            var stale = staleIDs(home: home, legacySourceExists: !sources(legacyIdentifier).isEmpty)
            if stale.contains(legacyIdentifier) {
                try unregisterCopies(except: nil, ids: [legacyIdentifier])
            }
            if command == "uninstall" { stale.formUnion(ownedIDs) }
            try cleanPreferences(removing: stale)
            if command == "uninstall" && deleteData {
                for id in ownedIDs {
                    if let keys = CFPreferencesCopyKeyList(id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) {
                        CFPreferencesSetMultiple(nil, keys, id as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                        guard CFPreferencesAppSynchronize(id as CFString) else { throw Failure(message: "無法清除倉頡星偏好快取。") }
                    }
                }
                // Synchronizing cached defaults can recreate an empty plist; remove it last.
                try purgeUserData(home: home)
                try purgePrivateCaches(root: privateCacheRoot())
            }
            try refreshCatalog(clearShared: command == "uninstall")
            if command == "uninstall" {
                let verification = removalVerification(home: home, deleteData: deleteData, catalogHasSource: false, cacheRoot: deleteData ? try privateCacheRoot() : nil)
                guard verification.remainingFiles.isEmpty && !verification.remainingPreferenceEntries else {
                    throw Failure(message: "解除安裝尚未完成，仍有殘留檔案或輸入源記錄：\n" + verification.remainingFiles.joined(separator: "\n"))
                }
            }
            print(command == "repair" ? "已刷新倉頡星註冊與選單。" : "已移除目前使用者的 V2 輸入法與安裝記錄；" + (deleteData ? "設定及詞頻已刪除。" : "設定及詞頻保留。"))
            print("請重新開啟系統設定，核對已加入與可加入清單，並打開右上角選單驗證。若仍顯示舊資料，請保存工作後登出並重新登入。")
        default:
            throw Failure(message: "用法：CangjieXMaintenance status | check | repair | uninstall")
        }
    }
}

#if MAINTENANCE_TOOL
@main
struct MaintenanceMain {
    static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "uninstall-dialog"] {
            let status = UninstallUI.runDialog()
            UninstallUI.removeTemporaryHelper()
            exit(status)
        }
        do {
            guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--delete-data") else {
                throw InputSourceMaintenance.Failure(message: "用法：CangjieXMaintenance status | check | repair | uninstall [--delete-data]")
            }
            try InputSourceMaintenance.execute(CommandLine.arguments[1], deleteData: CommandLine.arguments.count == 3)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
#endif
