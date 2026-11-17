import AppKit
import CryptoKit

enum InstallUI {
    struct PayloadMetadata: Codable {
        let identity: RuntimeBuildIdentity
        let sha256: String
    }

    static func validateDestination(home: URL, version: String) throws {
        let app = InputSourceMaintenance.appURL(home: home)
        try InputSourceMaintenance.validateParents(of: app, home: home)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: app.path) else { return }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw InputSourceMaintenance.Failure(message: "安裝位置不是一般程式目錄，停止安裝。")
        }
        let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard let id = info?["CFBundleIdentifier"] as? String, InputSourceMaintenance.ownedIDs.contains(id) else {
            throw InputSourceMaintenance.Failure(message: "安裝位置已有其他程式，不會覆寫它。")
        }
        if let current = info?["CFBundleShortVersionString"] as? String,
           current.compare(version, options: .numeric) == .orderedDescending {
            throw InputSourceMaintenance.Failure(message: "目前已安裝較新的 \(current)，不會降級為 \(version)。")
        }
    }

    static func verifyPayload(_ package: URL, metadata: PayloadMetadata) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: package.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              SHA256.hash(data: try Data(contentsOf: package)).map({ String(format: "%02x", $0) }).joined() == metadata.sha256 else {
            throw InputSourceMaintenance.Failure(message: "內附安裝包校驗失敗，尚未安裝任何檔案。請重新下載安裝器。")
        }
    }

    static func install(expected: RuntimeBuildIdentity, preflight: () throws -> Void,
                        stopCurrent: () throws -> Void, writePackage: () throws -> Void,
                        inspect: () throws -> RuntimeBuildIdentity,
                        activate: () throws -> UpgradeActivation.Result) throws -> UpgradeActivation.Result {
        try preflight()
        try stopCurrent()
        try preflight()
        try writePackage()
        guard try inspect() == expected else {
            throw InputSourceMaintenance.Failure(message: "寫入的程式與此安裝器版本不符，不能宣稱升級完成。")
        }
        return try activate()
    }

    static func introduction(version: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "安裝倉頡星 \(version)"
        alert.informativeText = "先完成正在輸入的文字，切換到 ABC，並結束「系統設定」（Command＋Q）。安裝期間請保持 ABC。\n\n安裝器會保留設定與學習記錄，安裝後安全重啟輸入法，再核對實際執行的版本。V1 舊版及其他輸入法會保留。"
        alert.addButton(withTitle: "安裝並啟用")
        alert.addButton(withTitle: "取消")
        return alert
    }

    static func completion(_ result: UpgradeActivation.Result) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = result.active ? "已完成安裝並啟用新版" : "檔案已安裝，啟用尚未完成"
        alert.informativeText = result.message + (result.active ? "\n\n設定與詞頻已保留。現在可直接使用倉頡星。" : "\n\n設定與詞頻已保留。請依提示重新登入，再使用新版。")
        alert.addButton(withTitle: "好")
        return alert
    }

    static func run(bundle: Bundle) -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.finishLaunching()
        application.activate(ignoringOtherApps: true)
        var writingStarted = false
        let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 115), styleMask: [.titled], backing: .buffered, defer: false)
        progress.title = "正在安裝並核對執行版本"
        progress.isReleasedWhenClosed = false
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 45, width: 24, height: 24))
        spinner.style = .spinning
        spinner.usesThreadedAnimation = true
        let label = NSTextField(wrappingLabelWithString: "請保持 ABC。正在安裝、重新啟動，並核對執行版本…")
        label.frame = NSRect(x: 64, y: 32, width: 290, height: 48)
        progress.contentView?.addSubview(spinner)
        progress.contentView?.addSubview(label)
        do {
            guard let resources = bundle.resourceURL else { throw InputSourceMaintenance.Failure(message: "安裝器內容不完整。") }
            let metadata = try JSONDecoder().decode(PayloadMetadata.self, from: Data(contentsOf: resources.appendingPathComponent("InstallerPayload.json")))
            let package = resources.appendingPathComponent("InstallerPayload.pkg")
            try verifyPayload(package, metadata: metadata)
            guard introduction(version: metadata.identity.version).runModal() == .alertFirstButtonReturn else { return 0 }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let app = InputSourceMaintenance.appURL(home: home)
            let check = {
                try InputSourceMaintenance.preflight()
                try validateDestination(home: home, version: metadata.identity.version)
            }
            try check()
            progress.center()
            progress.makeKeyAndOrderFront(nil)
            spinner.startAnimation(nil)
            progress.displayIfNeeded()
            let result = try install(expected: metadata.identity, preflight: check, stopCurrent: {
                try InputSourceMaintenance.stop([app.appendingPathComponent("Contents/MacOS/CangjieXPreview").path])
            }, writePackage: {
                writingStarted = true
                _ = try InputSourceMaintenance.run("/usr/sbin/installer", ["-pkg", package.path, "-target", "CurrentUserHomeDirectory"])
            }, inspect: { try UpgradeActivation.installedIdentity(at: app) }, activate: UpgradeActivation.activateInstalled)
            progress.close()
            let alert = completion(result)
            application.activate(ignoringOtherApps: true)
            alert.runModal()
            return result.active ? 0 : 2
        } catch {
            progress.close()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = writingStarted ? "安裝或啟用尚未完成" : "尚未開始安裝"
            alert.informativeText = error.localizedDescription + (writingStarted ? "\n\n請保存工作後重新登入。若仍無法啟用，請重新執行安裝器；目前不算完成升級。" : "\n\n尚未寫入新版檔案，也未修改設定與學習記錄。完成上述步驟後，可重新執行安裝器。")
            alert.addButton(withTitle: "好")
            application.activate(ignoringOtherApps: true)
            alert.runModal()
            return 1
        }
    }
}
