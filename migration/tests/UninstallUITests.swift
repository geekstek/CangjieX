import AppKit

@main
struct UninstallUITests {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw InputSourceMaintenance.Failure(message: message) }
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        if CommandLine.arguments.contains("--diagnostics-preview") {
            _ = DiagnosticsUI.runChoice(DiagnosticsUI.introduction())
            print("Diagnostics preview closed; no diagnostics export or recovery was executed.")
            return
        }
        if CommandLine.arguments.contains("--confirmation-preview") {
            let result = UninstallUI.runConfirmation(UninstallUI.confirmation())
            print("Preview confirmation response: \(result.rawValue). No uninstall action is executed in this test host.")
            return
        }
        if CommandLine.arguments.contains("--about-preview") || Bundle.main.bundleIdentifier == "io.github.geekstek.cangjiex.uninstall-visual-check" {
            let window = PreviewAboutWindow(version: "2.0.4", launch: { _ in
                let alert = UninstallUI.confirmation()
                _ = UninstallUI.runConfirmation(alert)
                // UI preview is deliberately disconnected from the real maintenance tool.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                try process.run()
                return process
            })
            window.present()
            withExtendedLifetime(window) { app.run() }
            return
        }
        let confirmation = UninstallUI.confirmation()
        try check(confirmation.buttons.count == 2, "Confirmation actions changed")
        try check(confirmation.buttons[0].hasDestructiveAction && confirmation.buttons[0].keyEquivalent.isEmpty,
                  "Delete must require an explicit click")
        try check(confirmation.window.defaultButtonCell === confirmation.buttons[1].cell && confirmation.buttons[1].title == "取消",
                  "Cancel must be the default action")
        try check((confirmation.accessoryView as? NSButton)?.state == .on && confirmation.informativeText.contains("永久刪除"),
                  "Complete removal needs explicit data disclosure and a visible choice")
        confirmation.window.close()
        for (code, characters) in [(UInt16(36), "\r"), (53, "\u{1b}")] {
            let dialog = UninstallUI.confirmation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: dialog.window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
                NSApp.postEvent(event, atStart: true)
            }
            try check(UninstallUI.runConfirmation(dialog) == .alertSecondButtonReturn, "Return/Escape must cancel confirmation")
        }

        var preparations = 0
        var launches = 0
        let about = PreviewAboutWindow(version: "2.0.1", launch: { prepare in
            try prepare()
            launches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["0.2"]
            try process.run()
            return process
        })
        about.present { preparations += 1 }
        about.uninstallButton.performClick(nil)
        about.uninstallButton.performClick(nil)
        try check(preparations == 1 && launches == 1 && !about.uninstallButton.isEnabled, "Repeated clicks launched multiple uninstallers")
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        try check(about.uninstallButton.isEnabled, "Cancel/exit should allow retry")
        about.close()

        var diagnosticsLaunches = 0
        let diagnosticsAbout = PreviewAboutWindow(version: "2.0.4", launch: { _ in
            throw InputSourceMaintenance.Failure(message: "Unexpected uninstall dispatch")
        }, diagnosticsLaunch: {
            diagnosticsLaunches += 1
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["0.1"]
            try process.run()
            return process
        })
        diagnosticsAbout.present()
        diagnosticsAbout.diagnosticsButton.performClick(nil)
        diagnosticsAbout.diagnosticsButton.performClick(nil)
        try check(diagnosticsLaunches == 1 && !diagnosticsAbout.uninstallButton.isEnabled && !diagnosticsAbout.diagnosticsButton.isEnabled,
                  "Diagnostics launch is not independent or double-click guarded")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        try check(diagnosticsAbout.diagnosticsButton.isEnabled && diagnosticsAbout.uninstallButton.isEnabled, "Diagnostics tool exit did not allow retry")
        let output = URL(fileURLWithPath: "build/migration/maintenance")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let content = diagnosticsAbout.window!.contentView!
            content.appearance = NSAppearance(named: appearance)
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            diagnosticsAbout.window!.display()
            try check(diagnosticsAbout.diagnosticsButton.frame.width > 300 && diagnosticsAbout.diagnosticsButton.frame.height >= 18, "About diagnostics control was never laid out")
            try check(content.bounds.contains(diagnosticsAbout.diagnosticsButton.convert(diagnosticsAbout.diagnosticsButton.bounds, to: content)), "About diagnostics button is clipped")
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("diagnostics-about-\(name).png"))
            let alert = DiagnosticsUI.introduction()
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            let view = alert.window.contentView!
            view.layoutSubtreeIfNeeded()
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("diagnostics-dialog-\(name).png"))
            try check(alert.buttons.count == 3 && alert.window.defaultButtonCell === alert.buttons[2].cell,
                      "Diagnostic dialog should default to close, not mutate input sources")
            alert.window.close()
        }
        diagnosticsAbout.close()
        let closeChoice = DiagnosticsUI.introduction()
        DispatchQueue.main.async {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: closeChoice.window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            NSApp.postEvent(event, atStart: true)
        }
        try check(DiagnosticsUI.runChoice(closeChoice) == .alertThirdButtonReturn, "Escape must close diagnostics without a repair or export")
        closeChoice.window.close()

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cjx-stage-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let bundle = temporary.appendingPathComponent("CangjieXPreview.app")
        let bin = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": InputSourceMaintenance.identifier, "CFBundleDisplayName": "倉頡星",
                    "CFBundleExecutable": "CangjieXPreview", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let fixtureSource = temporary.appendingPathComponent("helper.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: fixtureSource)
        let fixtureBinary = temporary.appendingPathComponent("helper")
        _ = try InputSourceMaintenance.run("/usr/bin/xcrun", ["clang", fixtureSource.path, "-o", fixtureBinary.path])
        let bytes = try Data(contentsOf: fixtureBinary)
        for name in ["CangjieXPreview", "CangjieXMaintenance"] {
            let file = bin.appendingPathComponent(name)
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--force", "--sign", "-", file.path])
        }
        _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        let staged = try UninstallUI.stageHelper(from: bundle)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: bundle)
        _ = try InputSourceMaintenance.run(staged.path, ["uninstall-dialog"])
        let attributes = try FileManager.default.attributesOfItem(atPath: staged.deletingLastPathComponent().path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Staged helper directory must be private")
        print("PASS: destructive confirmation/cancel default, data disclosure, About button dispatch, double-click guard, retry and signed helper surviving app removal; no real input-source changes.")
    }
}
