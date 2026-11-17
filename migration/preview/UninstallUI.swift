import AppKit

enum UninstallUI {
    static func confirmation() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "解除安裝倉頡星？"
        alert.informativeText = "將移除目前使用者帳戶的倉頡星 V2 程式、輸入來源及安裝記錄，並切換到 ABC。舊版及其他輸入法會保留。\n\n勾選下方選項，也會永久刪除你的輸入設定與學習記錄。"
        alert.addButton(withTitle: "解除安裝").hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "取消")
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        cancel.keyEquivalent = "\r"
        cancel.keyEquivalentModifierMask = []
        alert.buttons[0].keyEquivalent = ""
        let option = NSButton(checkboxWithTitle: "一併刪除設定與學習記錄（無法復原）", target: nil, action: nil)
        option.state = .on
        option.setAccessibilityLabel("一併刪除設定與學習記錄，無法復原")
        alert.accessoryView = option
        return alert
    }

    static func runConfirmation(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Neither Return nor Escape may confirm a destructive action, regardless of focus.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.modalWindow === alert.window && [UInt16(36), 76, 53].contains(event.keyCode) {
                NSApp.stopModal(withCode: .alertSecondButtonReturn)
                return nil
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }

    static func stageHelper(from bundle: URL) throws -> URL {
        try InputSourceMaintenance.validateApp(bundle)
        _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--verify", "--strict", bundle.path])
        let source = bundle.appendingPathComponent("Contents/MacOS/CangjieXMaintenance")
        _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--verify", "--strict", source.path])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CangjieX-uninstall-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let target = directory.appendingPathComponent("CangjieXMaintenance")
            try FileManager.default.copyItem(at: source, to: target)
            _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--verify", "--strict", target.path])
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func launch(prepare: () throws -> Void) throws -> Process {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle == InputSourceMaintenance.appURL(home: FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL else {
            throw InputSourceMaintenance.Failure(message: "請從已安裝的倉頡星選單執行解除安裝；開發副本不會移除日常安裝。")
        }
        let helper = try stageHelper(from: bundle)
        do {
            try prepare()
            let process = Process()
            process.executableURL = helper
            process.arguments = ["uninstall-dialog"]
            try process.run()
            return process
        } catch {
            try? FileManager.default.removeItem(at: helper.deletingLastPathComponent())
            throw error
        }
    }

    static func runDialog() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        do {
            try InputSourceMaintenance.checkEnvironment(running: InputSourceMaintenance.processes(), uid: getuid())
            try InputSourceMaintenance.validateApp(InputSourceMaintenance.appURL(home: FileManager.default.homeDirectoryForCurrentUser))
        } catch {
            let blocked = NSAlert()
            blocked.messageText = "暫時無法解除安裝"
            blocked.informativeText = error.localizedDescription + "\n\n尚未刪除程式、設定或學習記錄。"
            blocked.addButton(withTitle: "好")
            blocked.runModal()
            return 1
        }
        let confirmation = confirmation()
        guard runConfirmation(confirmation) == .alertFirstButtonReturn else { return 0 }
        let deleteData = (confirmation.accessoryView as? NSButton)?.state == .on
        let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        progress.title = "正在解除安裝倉頡星"
        progress.isReleasedWhenClosed = false
        let indicator = NSProgressIndicator(frame: NSRect(x: 24, y: 34, width: 24, height: 24))
        indicator.style = .spinning
        indicator.usesThreadedAnimation = true
        let label = NSTextField(labelWithString: "正在移除程式與清理輸入來源…")
        label.frame = NSRect(x: 64, y: 34, width: 250, height: 24)
        progress.contentView?.addSubview(indicator)
        progress.contentView?.addSubview(label)
        do {
            try InputSourceMaintenance.checkEnvironment(running: InputSourceMaintenance.processes(), uid: getuid())
            try InputSourceMaintenance.selectABC()
            progress.center()
            progress.makeKeyAndOrderFront(nil)
            indicator.startAnimation(nil)
            progress.displayIfNeeded()
            try InputSourceMaintenance.execute("uninstall", deleteData: deleteData)
            // Query in a new process so this process's TIS cache cannot hide a remnant.
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let flags = ["verify-uninstall"] + (deleteData ? ["--delete-data"] : [])
            let output = try InputSourceMaintenance.run(executable.path, flags)
            let report = try JSONDecoder().decode(InputSourceMaintenance.RemovalVerification.self, from: Data(output.utf8))
            guard report.remainingFiles.isEmpty && !report.remainingPreferenceEntries else {
                throw InputSourceMaintenance.Failure(message: "仍有殘留檔案或輸入來源記錄：\n" + report.remainingFiles.joined(separator: "\n"))
            }
            progress.close()
            let result = NSAlert()
            result.messageText = report.needsRelogin ? "程式已移除，請登出完成清理" : "已解除安裝倉頡星"
            result.informativeText = (deleteData ? "V2 程式、設定、學習記錄與安裝記錄已移除。" : "V2 程式與安裝記錄已移除；設定及學習記錄已保留。")
                + "\n\n" + (report.needsRelogin ? "系統仍保留本次登入的輸入來源快取。請保存工作後登出並重新登入，以清除選單殘留。" : "已刷新輸入來源與選單快取。若系統設定仍顯示舊項目，請保存工作後登出並重新登入。")
            result.addButton(withTitle: "好")
            app.activate(ignoringOtherApps: true)
            result.runModal()
            return 0
        } catch {
            progress.close()
            let result = NSAlert()
            result.alertStyle = .warning
            result.messageText = "解除安裝未完成"
            result.informativeText = error.localizedDescription + "\n\n請先完成上述步驟再重試。部分清理可能已完成；不會自動登出或重新啟動。"
            result.addButton(withTitle: "好")
            app.activate(ignoringOtherApps: true)
            result.runModal()
            return 1
        }
    }

    static func removeTemporaryHelper() {
        let file = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let directory = file.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard file.lastPathComponent == "CangjieXMaintenance",
              directory.lastPathComponent.hasPrefix("CangjieX-uninstall-"),
              directory.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == temporary else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

final class PreviewAboutWindow: NSWindowController {
    static let shared = PreviewAboutWindow()
    let uninstallButton = NSButton(title: "解除安裝倉頡星…", target: nil, action: nil)
    private var prepare: () throws -> Void = {}
    private var operation: Process?
    private let launch: (() throws -> Void) throws -> Process

    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
         launch: @escaping (() throws -> Void) throws -> Process = UninstallUI.launch) {
        self.launch = launch
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "關於倉頡星"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .centerX
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 20, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        let icon = NSImageView()
        icon.image = Bundle.main.url(forResource: "Preview", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        icon.setAccessibilityElement(false)
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        root.addArrangedSubview(icon)
        let name = NSTextField(labelWithString: "倉頡星")
        name.font = .boldSystemFont(ofSize: 22)
        root.addArrangedSubview(name)
        let detail = NSTextField(labelWithString: "版本 \(version)  ·  Swift + Rust")
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        root.addArrangedSubview(detail)
        let description = NSTextField(wrappingLabelWithString: "倉頡與簡易輸入、聯想詞、注音文校正、繁簡轉換。\n設定與學習記錄儲存在本機，與舊版分開保存。")
        description.alignment = .center
        description.font = .systemFont(ofSize: 13)
        description.widthAnchor.constraint(equalToConstant: 380).isActive = true
        root.addArrangedSubview(description)
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 380).isActive = true
        root.addArrangedSubview(separator)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 16
        buttons.widthAnchor.constraint(equalToConstant: 380).isActive = true
        uninstallButton.bezelStyle = .rounded
        uninstallButton.hasDestructiveAction = true
        uninstallButton.target = self
        uninstallButton.action = #selector(uninstall(_:))
        uninstallButton.setAccessibilityLabel("解除安裝倉頡星，開啟確認視窗")
        buttons.addArrangedSubview(uninstallButton)
        buttons.addArrangedSubview(NSView())
        let close = NSButton(title: "關閉", target: self, action: #selector(closeAbout(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        buttons.addArrangedSubview(close)
        root.addArrangedSubview(buttons)
    }

    required init?(coder: NSCoder) { nil }

    func present(prepare: @escaping () throws -> Void = {}) {
        self.prepare = prepare
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func closeAbout(_ sender: Any?) { close() }

    @objc private func uninstall(_ sender: Any?) {
        guard operation == nil else { return }
        do {
            let process = try launch(prepare)
            operation = process
            uninstallButton.isEnabled = false
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.operation = nil
                    self?.uninstallButton.isEnabled = true
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "無法開始解除安裝"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            if let window { alert.beginSheetModal(for: window) }
        }
    }
}
