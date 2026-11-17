import AppKit
import InputMethodKit
import os

private struct IMKCompositionClient: CompositionClient {
    let client: any IMKTextInput
    func mark(_ text: String, selection: NSRange) {
        client.setMarkedText(text, selectionRange: selection, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func insert(_ text: String) {
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

@objc(CangjieXPreviewInputController)
final class PreviewInputController: IMKInputController {
    private weak var inputClient: (any IMKTextInput)?
    private let settingsStore = PreviewSettingsStore.shared
    private var settings = PreviewSettingsStore.shared.settings
    private lazy var composition: CompositionSession? = makeComposition()
    private func makeComposition() -> CompositionSession? {
        try? CompositionSession(flags: settings.flags,
            learningStore: settings.flags & UInt32(CJX_OPT_DYNAMIC_FREQUENCY) != 0
                ? (settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0 ? .simplex : .shared) : nil)
    }
    private var candidates: CandidateWindow?
    private let logger = Logger(subsystem: "io.github.geekstek.inputmethod.CangjieXPreview", category: "Input")

    override func recognizedEvents(_ sender: Any!) -> Int { Int(NSEvent.EventTypeMask.keyDown.rawValue) }

    private func resolveClient(_ sender: Any?) -> (any IMKTextInput)? {
        if let client = sender as? any IMKTextInput { inputClient = client }
        return inputClient ?? client()
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown,
              let client = resolveClient(sender) else { return false }
        let (key, modifiers) = PreviewKeyMapper.translate(event)
        if let text = PreviewKeyMapper.directText(characters: event.characters, key: key, modifiers: modifiers) {
            return processDirectText(text, client: client)
        }
        return process(key: key, modifiers: modifiers, client: client)
    }

    // Current IMK clients may deliver unpacked input instead of NSEvent.
    override func inputText(_ string: String!, key keyCode: Int, modifiers flags: Int, client sender: Any!) -> Bool {
        guard keyCode >= 0, keyCode <= Int(UInt16.max),
              let client = resolveClient(sender) else { return false }
        let (key, modifiers) = PreviewKeyMapper.translate(characters: string, keyCode: UInt16(keyCode),
                                                         flags: NSEvent.ModifierFlags(rawValue: UInt(bitPattern: flags)))
        if let text = PreviewKeyMapper.directText(characters: string, key: key, modifiers: modifiers) {
            return processDirectText(text, client: client)
        }
        return process(key: key, modifiers: modifiers, client: client)
    }

    override func inputText(_ string: String!, client sender: Any!) -> Bool {
        guard let string, let client = resolveClient(sender) else { return false }
        let special: [String: UInt32] = ["\r": UInt32(CJX_KEY_RETURN), "\u{7f}": UInt32(CJX_KEY_BACKSPACE),
                                         "\u{8}": UInt32(CJX_KEY_BACKSPACE), "\u{1b}": UInt32(CJX_KEY_ESCAPE)]
        let (key, modifiers) = PreviewKeyMapper.translate(characters: string, keyCode: 0, flags: NSEvent.modifierFlags)
        if let text = PreviewKeyMapper.directText(characters: string, key: key, modifiers: modifiers) {
            return processDirectText(text, client: client)
        }
        guard key != UInt32(CJX_KEY_OTHER) || special[string] != nil else { return false }
        return process(key: special[string] ?? key, modifiers: modifiers, client: client)
    }

    private func process(key: UInt32, modifiers: UInt32 = 0, client: any IMKTextInput) -> Bool {
        if let command = PreviewMenuCommand.shortcut(key: key, modifiers: modifiers) {
            performMenuCommand(command)
            return true
        }
        return dispatch(client: client) { try $0.handle(key: key, modifiers: modifiers, client: IMKCompositionClient(client: client)) }
    }

    private func processDirectText(_ text: String, client: any IMKTextInput) -> Bool {
        dispatch(client: client) { try $0.directText(text, client: IMKCompositionClient(client: client)) }
    }

    private func dispatch(client: any IMKTextInput, action: (CompositionSession) throws -> EngineSnapshot) -> Bool {
        _ = refreshSettings()
        guard let composition else { NSSound.beep(); return false }
        do {
            let snapshot = try action(composition)
            if snapshot.handled {
                if snapshot.beep && settings.playErrorSound { NSSound.beep() }
                let changed = refreshSettings()
                render(changed ? self.composition?.snapshot ?? .empty : snapshot, client: client)
            }
            return snapshot.handled
        } catch {
            // Never log user input or candidate text.
            logger.error("Preview input engine failed")
            NSSound.beep()
            return false
        }
    }

    private func render(_ snapshot: EngineSnapshot, client: any IMKTextInput) {
        guard snapshot.visible else { candidates?.hide(); return }
        var caret = NSRect.zero
        _ = client.attributes(forCharacterIndex: snapshot.correction ? snapshot.selectionLocation : max(0, snapshot.reading.utf16.count - 1), lineHeightRectangle: &caret)
        if !caret.origin.x.isFinite || !caret.origin.y.isFinite || caret == .zero {
            let point = NSEvent.mouseLocation
            caret = NSRect(origin: point, size: NSSize(width: 1, height: 18))
        }
        let panel = candidates ?? CandidateWindow()
        candidates = panel
        panel.show(snapshot, caret: caret, windowLevel: Int(client.windowLevel()), settings: settings, choose: { [weak self] index in
            guard let self else { return }
            let spaceFirst = self.settings.flags & UInt32(CJX_OPT_SPACE_SELECTS_FIRST) != 0 && !snapshot.correction
            guard let (key, modifiers) = PreviewKeyMapper.candidateSelection(index: index, associated: snapshot.associated,
                                                                          spaceFirst: spaceFirst) else { return }
            _ = self.process(key: key, modifiers: modifiers, client: client)
        }, turnPage: { [weak self] forward in
            _ = self?.process(key: UInt32(forward ? CJX_KEY_PAGE_DOWN : CJX_KEY_PAGE_UP), client: client)
        })
    }

    override func activateServer(_ sender: Any!) {
        guard let client = resolveClient(sender) else { return }
        try? composition?.cancel(client: IMKCompositionClient(client: client))
        settingsStore.reloadInheritedSettings()
        settings = settingsStore.settings
        composition = makeComposition()
        candidates?.hide()
    }

    override func deactivateServer(_ sender: Any!) {
        defer { candidates?.hide() }
        guard let client = resolveClient(sender) else { return }
        try? composition?.deactivate(client: IMKCompositionClient(client: client))
    }

    override func commitComposition(_ sender: Any!) {
        defer { candidates?.hide() }
        guard let client = resolveClient(sender) else { return }
        try? composition?.commit(client: IMKCompositionClient(client: client))
    }

    override func inputControllerWillClose() { candidates?.hide() }
    override func hidePalettes() { candidates?.hide() }

    override func menu() -> NSMenu! {
        PreviewMenuCommand.menu(settings: settingsStore.settings, target: self, action: #selector(previewMenuAction(_:)))
    }

    // Keep the current reading intact; apply input options after it has ended.
    @discardableResult
    private func refreshSettings() -> Bool {
        let next = settingsStore.settings
        guard next.flags != settings.flags else { settings = next; return false }
        guard composition?.snapshot.markedText.isEmpty != false else { return false }
        settings = next
        composition = makeComposition()
        candidates?.hide()
        return true
    }

    @objc func previewMenuAction(_ sender: Any?) {
        if let info = sender as? NSDictionary { _ = resolveClient(info[kIMKCommandClientName as String]) }
        guard let command = PreviewMenuCommand.from(sender: sender) else { return }
        performMenuCommand(command)
    }

    private func performMenuCommand(_ command: PreviewMenuCommand) {
        switch command {
        case .associated, .simplified, .fullwidth, .correction, .simplex, .cangjie:
            let flag = command == .cangjie ? UInt32(CJX_OPT_SIMPLEX) : UInt32(command.rawValue)
            do {
                try settingsStore.set(option: flag, enabled: command == .cangjie ? false : command == .simplex ? true : settingsStore.settings.flags & flag == 0)
                refreshSettings()
            } catch {
                logger.error("Could not save Preview settings")
                NSSound.beep()
            }
        case .symbols:
            NSApp.orderFrontCharacterPalette(nil)
        case .preferences:
            PreviewPreferencesWindow.shared.present()
        case .about:
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Preview"
            NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "倉頡星 Preview", .applicationVersion: version,
                .credits: NSAttributedString(string: "獨立 Preview，設定與學習記錄不會寫回舊版。\n\n已提供倉頡、簡易、注音文校正、聯想詞、繁簡及全形輸出。\n注音文校正處理輸入法收到的文字，不改寫已上屏內容或攔截貼上。")])
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
