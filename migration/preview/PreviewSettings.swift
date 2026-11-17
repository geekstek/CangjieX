import AppKit
import InputMethodKit

final class PreviewSettingsStore {
    static let shared = PreviewSettingsStore()
    private struct Overrides: Codable {
        var enabled: UInt32 = 0
        var disabled: UInt32 = 0
        var simplexEnabled: UInt32?
        var simplexDisabled: UInt32?
        var fontSize: Double?
        var playErrorSound: Bool?
    }
    private let home: URL
    private let url: URL
    private var overrides: Overrides
    private var inherited: LegacySettings
    private var inheritedSimplex: LegacySettings

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        inherited = .load(home: home)
        inheritedSimplex = .load(home: home, simplex: true)
        url = home.appendingPathComponent("Library/Application Support/CangjieX Preview/settings.json")
        overrides = (try? JSONDecoder().decode(Overrides.self, from: Data(contentsOf: url))) ?? Overrides()
    }

    var settings: LegacySettings {
        let simplex = overrides.enabled & UInt32(CJX_OPT_SIMPLEX) != 0
        let enabled = simplex ? (overrides.enabled & ~127) | (overrides.simplexEnabled ?? 0) : overrides.enabled
        let disabled = simplex ? (overrides.disabled & ~127) | (overrides.simplexDisabled ?? 0) : overrides.disabled
        return LegacySettings(base: simplex ? inheritedSimplex : inherited, enabled: enabled, disabled: disabled,
                              fontSize: overrides.fontSize, playErrorSound: overrides.playErrorSound)
    }

    func reloadInheritedSettings() {
        inherited = .load(home: home)
        inheritedSimplex = .load(home: home, simplex: true)
    }

    func set(option: UInt32, enabled: Bool) throws {
        guard option != 0, option & (option - 1) == 0, option & ~4095 == 0 else { return }
        var next = overrides
        if option <= 64 && settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0 {
            next.simplexEnabled = enabled ? (next.simplexEnabled ?? 0) | option : (next.simplexEnabled ?? 0) & ~option
            next.simplexDisabled = enabled ? (next.simplexDisabled ?? 0) & ~option : (next.simplexDisabled ?? 0) | option
        } else {
            next.enabled = enabled ? next.enabled | option : next.enabled & ~option
            next.disabled = enabled ? next.disabled & ~option : next.disabled | option
        }
        try save(next)
    }

    func set(fontSize: CGFloat) throws {
        guard fontSize.isFinite else { return }
        var next = overrides
        next.fontSize = Double(min(96, max(16, fontSize)))
        try save(next)
    }

    func set(playErrorSound: Bool) throws {
        var next = overrides
        next.playErrorSound = playErrorSound
        try save(next)
    }

    private func save(_ next: Overrides) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        overrides = next
    }
}

enum PreviewMenuCommand: Int {
    case associated = 256, simplified = 128, fullwidth = 512
    case correction = 2048, simplex = 1024
    case symbols = 2001, preferences, about, cangjie

    static func from(sender: Any?) -> Self? {
        let item = sender as? NSMenuItem ?? (sender as? NSDictionary)?[kIMKCommandMenuItemName as String] as? NSMenuItem
        return item.flatMap { Self(rawValue: $0.tag) }
    }

    static func shortcut(key: UInt32, modifiers: UInt32) -> Self? {
        let modifiers = modifiers & ~UInt32(CJX_MOD_CAPS_LOCK)
        if modifiers == UInt32(CJX_MOD_COMMAND | CJX_MOD_CONTROL) {
            if key == 103 { return .simplified }
            if key == 46 { return .symbols }
        }
        if key == 32 && modifiers == UInt32(CJX_MOD_COMMAND | CJX_MOD_SHIFT) { return .fullwidth }
        return nil
    }

    static func menu(settings: LegacySettings, target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "倉頡星")
        menu.autoenablesItems = false
        func add(_ title: String, command: Self, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.tag = command.rawValue
            item.keyEquivalentModifierMask = modifiers
            if [.associated, .simplified, .fullwidth, .correction, .simplex].contains(command) {
                item.state = settings.flags & UInt32(command.rawValue) != 0 ? .on : .off
            }
            if command == .cangjie { item.state = settings.flags & UInt32(CJX_OPT_SIMPLEX) == 0 ? .on : .off }
            menu.addItem(item)
        }
        add("倉頡", command: .cangjie)
        add("簡易", command: .simplex)
        menu.addItem(.separator())
        add("注音文校正", command: .correction)
        add("聯想詞提示", command: .associated)
        menu.addItem(.separator())
        add("使用全形英數字", command: .fullwidth, key: " ", modifiers: [.command, .shift])
        add("繁體轉簡體", command: .simplified, key: "g", modifiers: [.command, .control])
        menu.addItem(.separator())
        add("符號表（系統）…", command: .symbols, key: ".", modifiers: [.command, .control])
        add("偏好設定…", command: .preferences)
        add("關於倉頡星", command: .about)
        return menu
    }
}

private final class PreferencesBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}

final class PreviewPreferencesWindow: NSWindowController {
    static let shared = PreviewPreferencesWindow(store: .shared)
    private let store: PreviewSettingsStore
    private let tabs = NSTabView()
    private var checkboxes: [NSButton] = []
    private let fontPicker = NSPopUpButton()
    private let modePicker = NSPopUpButton()
    private let sound = NSButton(checkboxWithTitle: "錯碼時播放提示音", target: nil, action: nil)

    init(store: PreviewSettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "倉頡星 偏好設定"
        window.isReleasedWhenClosed = false
        window.contentView = PreferencesBackground(frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        super.init(window: window)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 16
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        root.addArrangedSubview(tabs)
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(equalToConstant: 440).isActive = true
        tabs.heightAnchor.constraint(equalToConstant: 296).isActive = true
        func tab(_ title: String) -> NSStackView {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
            let container = NSView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stack.topAnchor.constraint(equalTo: container.topAnchor)])
            item.view = container
            tabs.addTabViewItem(item)
            return stack
        }
        func option(_ title: String, flag: Int, in stack: NSStackView) {
            let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(changeOption(_:)))
            button.tag = flag
            checkboxes.append(button)
            stack.addArrangedSubview(button)
        }
        let input = tab("輸入")
        modePicker.addItems(withTitles: ["倉頡", "簡易"])
        modePicker.setAccessibilityLabel("輸入方式")
        modePicker.target = self
        modePicker.action = #selector(changeMode(_:))
        input.addArrangedSubview(modePicker)
        option("即時顯示候選", flag: CJX_OPT_COMPOSE_WHILE_TYPING, in: input)
        option("滿五個字根時自動確認", flag: CJX_OPT_COMMIT_AT_MAXIMUM, in: input)
        option("錯碼時清除字根", flag: CJX_OPT_CLEAR_ON_ERROR, in: input)
        option("依選字習慣調整候選順序", flag: CJX_OPT_DYNAMIC_FREQUENCY, in: input)
        option("空格作為第一候選鍵（其餘編號從 1 開始）", flag: CJX_OPT_SPACE_SELECTS_FIRST, in: input)
        option("只有一頁時，空格直接選第一項", flag: CJX_OPT_SPACE_SELECTS_ONE_PAGE, in: input)
        let output = tab("輸出")
        option("注音文校正", flag: CJX_OPT_BOPOMOFO_CORRECTION, in: output)
        option("聯想詞提示", flag: CJX_OPT_ASSOCIATED_PHRASES, in: output)
        option("繁體轉簡體", flag: CJX_OPT_SIMPLIFIED_OUTPUT, in: output)
        option("使用全形英數字", flag: CJX_OPT_FULLWIDTH_OUTPUT, in: output)
        option("使用半角標點覆蓋表", flag: CJX_OPT_HALFWIDTH_PUNCTUATION, in: output)
        let appearance = tab("候選與提示")
        let fontRow = NSStackView()
        fontRow.orientation = .horizontal
        fontRow.spacing = 12
        fontRow.addArrangedSubview(NSTextField(labelWithString: "候選字大小"))
        fontPicker.target = self
        fontPicker.action = #selector(changeFont(_:))
        fontPicker.setAccessibilityLabel("候選字大小")
        fontPicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        fontRow.addArrangedSubview(fontPicker)
        appearance.addArrangedSubview(fontRow)
        sound.target = self
        sound.action = #selector(changeSound(_:))
        appearance.addArrangedSubview(sound)
        let hint = NSTextField(wrappingLabelWithString: "跟隨系統淺色與深色外觀。\n候選高亮色沿用舊版目前設定。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        appearance.addArrangedSubview(hint)
        let footer = NSTextField(wrappingLabelWithString: "設定及學習記錄與舊版分開保存。\n輸入選項於目前組字結束後生效。")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.widthAnchor.constraint(equalToConstant: 440).isActive = true
        root.addArrangedSubview(footer)
        reload()
        window.center()
    }

    required init?(coder: NSCoder) { return nil }

    func present() {
        reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        let settings = store.settings
        modePicker.selectItem(at: settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0 ? 1 : 0)
        for button in checkboxes {
            button.state = settings.flags & UInt32(button.tag) != 0 ? .on : .off
            if button.tag == CJX_OPT_COMMIT_AT_MAXIMUM {
                button.title = settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0 ? "滿兩個字根時自動確認" : "滿五個字根時自動確認"
            }
        }
        sound.state = settings.playErrorSound ? .on : .off
        let sizes = Set([16, 17, 18, 20, 24, 28, 32].map { CGFloat($0) } + [settings.fontSize]).sorted()
        fontPicker.removeAllItems()
        for size in sizes { fontPicker.addItem(withTitle: String(format: "%g pt", Double(size))) }
        fontPicker.selectItem(at: sizes.firstIndex(of: settings.fontSize)!)
        for (item, size) in zip(fontPicker.itemArray, sizes) { item.representedObject = size }
    }

    private func save(_ operation: () throws -> Void) {
        do { try operation() }
        catch {
            let alert = NSAlert()
            alert.messageText = "無法儲存倉頡星設定"
            alert.informativeText = "請檢查倉頡星資料目錄的寫入權限。"
            alert.alertStyle = .warning
            if let window { alert.beginSheetModal(for: window) }
        }
        reload()
    }
    @objc private func changeMode(_ sender: NSPopUpButton) {
        save { try store.set(option: UInt32(CJX_OPT_SIMPLEX), enabled: sender.indexOfSelectedItem == 1) }
    }
    @objc private func changeOption(_ sender: NSButton) {
        save { try store.set(option: UInt32(sender.tag), enabled: sender.state == .on) }
    }
    @objc private func changeFont(_ sender: NSPopUpButton) {
        guard let size = sender.selectedItem?.representedObject as? CGFloat else { return }
        save { try store.set(fontSize: size) }
    }
    @objc private func changeSound(_ sender: NSButton) { save { try store.set(playErrorSound: sender.state == .on) } }
}
