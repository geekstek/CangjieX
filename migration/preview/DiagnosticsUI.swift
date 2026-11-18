import AppKit

enum DiagnosticsUI {
    static func launch() throws -> Process {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard InputSourceMaintenance.isInstalledLocation(bundle) else {
            throw InputSourceMaintenance.Failure(message: "請從已安裝的倉頡星開啟診斷工具。")
        }
        let helper = try UninstallUI.stageHelper(from: bundle)
        do {
            let task = Process()
            task.executableURL = helper
            task.arguments = ["diagnostics-dialog"]
            try task.run()
            return task
        } catch {
            try? FileManager.default.removeItem(at: helper.deletingLastPathComponent())
            throw error
        }
    }

    static func introduction() -> NSAlert {
        let alert = NSAlert()
        alert.icon = NSImage(contentsOf: InputSourceMaintenance.appURL(home: FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Contents/Resources/Preview.icns")) ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        alert.messageText = "倉頡星診斷與修復"
        alert.informativeText = "診斷僅記錄版本、輸入源狀態、錯誤代碼及連線事件，不包含輸入文字、候選內容或詞頻，也不會自動上傳。\n\n無法切換時，先完成文字、切換到 ABC、離開密碼欄位，並結束「系統設定」，再按修復。修復會先保存診斷，保留設定與學習記錄。"
        alert.addButton(withTitle: "儲存診斷記錄")
        alert.addButton(withTitle: "修復輸入法")
        let close = alert.addButton(withTitle: "關閉")
        alert.window.defaultButtonCell = close.cell as? NSButtonCell
        close.keyEquivalent = "\r"
        alert.buttons[0].keyEquivalent = ""
        return alert
    }

    static func runChoice(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.modalWindow === alert.window && event.keyCode == 53 {
                NSApp.stopModal(withCode: .alertThirdButtonReturn)
                return nil
            }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }

    static func runDialog() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.activate(ignoringOtherApps: true)
        while true {
            let response = runChoice(introduction())
            guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return 0 }
            let progress = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 105), styleMask: [.titled], backing: .buffered, defer: false)
            progress.title = response == .alertFirstButtonReturn ? "正在儲存診斷記錄" : "正在診斷並修復"
            progress.isReleasedWhenClosed = false
            let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 36, width: 24, height: 24))
            spinner.style = .spinning
            spinner.usesThreadedAnimation = true
            let text = NSTextField(wrappingLabelWithString: "請稍候，診斷資料僅保存在本機。")
            text.frame = NSRect(x: 65, y: 29, width: 265, height: 44)
            progress.contentView?.addSubview(spinner)
            progress.contentView?.addSubview(text)
            progress.center(); progress.makeKeyAndOrderFront(nil); spinner.startAnimation(nil); progress.displayIfNeeded()
            let result = NSAlert()
            do {
                if response == .alertFirstButtonReturn {
                    let file = try DiagnosticReport.export()
                    result.messageText = "診斷記錄已儲存"
                    result.informativeText = "檔案已保存在本機，沒有上傳。你可自行檢查或提供給開發者。"
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                } else {
                    let status = try DiagnosticReport.recoverInstalled()
                    result.messageText = status.active ? "系統已恢復選用倉頡星" : "修復尚未完成"
                    result.informativeText = status.active ? "已核對執行版本與系統選用狀態。請回到原本的軟體實際試打，確認選單與輸入均正常。\n\n修復前後的診斷已保留，設定與詞頻未刪除。" : status.message
                }
            } catch {
                result.alertStyle = .warning
                result.messageText = "診斷或修復尚未完成"
                result.informativeText = error.localizedDescription
            }
            progress.close()
            result.addButton(withTitle: "好")
            app.activate(ignoringOtherApps: true)
            result.runModal()
        }
    }
}
