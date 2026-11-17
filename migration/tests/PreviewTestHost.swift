import AppKit
import Carbon

@main
private final class PreviewTestHost: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let editor = NSTextView()
    private let secondEditor = NSTextView()
    private let status = NSTextField(labelWithString: "先按「使用 Preview」，輸入 a，再按畫面上的數字選字。")
    private var originalSource: String?

    static func main() {
        let app = NSApplication.shared
        let delegate = PreviewTestHost()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 320, y: 280, width: 640, height: 440),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "倉頡星 Preview 試打"
        window.delegate = self
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let actions = NSStackView()
        actions.spacing = 8
        actions.addArrangedSubview(NSButton(title: "使用 Preview", target: self, action: #selector(selectPreview)))
        actions.addArrangedSubview(NSButton(title: "使用舊版", target: self, action: #selector(selectLegacy)))
        actions.addArrangedSubview(NSButton(title: "還原輸入源", target: self, action: #selector(restoreSource)))
        root.addArrangedSubview(actions)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status)
        for (index, view) in [editor, secondEditor].enumerated() {
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.font = .systemFont(ofSize: 22)
            view.frame = NSRect(x: 0, y: 0, width: 608, height: 140)
            view.autoresizingMask = [.width]
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.textContainerInset = NSSize(width: 8, height: 8)
            view.setAccessibilityLabel(index == 0 ? "Preview 試打輸入框" : "第二個輸入框，測試焦點切換")
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = view
            scroll.translatesAutoresizingMaskIntoConstraints = false
            root.addArrangedSubview(scroll)
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        }
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func selectPreview() {
        window.makeFirstResponder(editor)
        guard let context = editor.inputContext else { return }
        if originalSource == nil { originalSource = context.selectedKeyboardInputSource }
        let identifier = "io.github.geekstek.inputmethod.CangjieXPreview"
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
        guard sources.count == 1, let source = sources.first,
              let bundle = TISGetInputSourceProperty(source, kTISPropertyBundleID),
              Unmanaged<AnyObject>.fromOpaque(bundle).takeUnretainedValue() as? String == identifier else {
            status.stringValue = "找不到唯一的 Preview 輸入源；未更動其他輸入源。"
            return
        }
        let enabled = TISEnableInputSource(source)
        guard enabled == noErr else {
            status.stringValue = "Preview 啟用失敗：\(enabled)"
            return
        }
        let selected = TISSelectInputSource(source)
        guard selected == noErr else {
            status.stringValue = "Preview 切換失敗：\(selected)"
            return
        }
        context.selectedKeyboardInputSource = identifier
        guard context.selectedKeyboardInputSource == identifier else {
            status.stringValue = "Preview 尚未進入此輸入框；目前為 \(context.selectedKeyboardInputSource ?? "無")"
            return
        }
        status.stringValue = "目前輸入源：\(context.selectedKeyboardInputSource ?? "無")"
    }

    @objc private func selectLegacy() {
        window.makeFirstResponder(editor)
        guard let context = editor.inputContext else { return }
        if originalSource == nil { originalSource = context.selectedKeyboardInputSource }
        context.selectedKeyboardInputSource = "io.github.geekstek.inputmethod.CangjieX"
        status.stringValue = "目前輸入源：\(context.selectedKeyboardInputSource ?? "無")"
    }

    @objc private func restoreSource() {
        window.makeFirstResponder(editor)
        if let originalSource { editor.inputContext?.selectedKeyboardInputSource = originalSource }
        status.stringValue = "已還原輸入源：\(editor.inputContext?.selectedKeyboardInputSource ?? "無")"
    }

    func windowWillClose(_ notification: Notification) {
        restoreSource()
        NSApp.terminate(nil)
    }
}
