import AppKit
import Foundation
import InputMethodKit

private enum TestFailure: Error { case failed(String) }

private func check(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure.failed(message) }
}

private final class TestClient: CompositionClient {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    var inserts: [String] = []
    var selections: [NSRange] = []
    func mark(_ text: String, selection: NSRange) {
        selections.append(selection)
        view.setMarkedText(text, selectedRange: selection, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func insert(_ text: String) {
        inserts.append(text)
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

private final class TestMenuTarget: NSObject {
    var commands: [PreviewMenuCommand] = []
    @objc func receive(_ sender: Any?) {
        if let command = PreviewMenuCommand.from(sender: sender) { commands.append(command) }
    }
}

private struct Frame: Decodable {
    let handled: Bool
    let reading: String
    let committed: String
    let beep: Bool
    let visible: Bool
    let page: Int
    let highlight: Int
    let candidates: [String]
    let composing: String?
    let cursor: Int?
}
private struct Scenario: Decodable { let id: String; let events: [String]; let expected: [Frame] }
private struct Baselines: Decodable { let profile_flags: UInt32?; let cases: [Scenario] }

private func event(_ token: String) throws -> NSEvent {
    let named: [String: (UInt16, String)] = [
        "space": (49, " "), "return": (36, "\r"), "backspace": (51, "\u{7f}"),
        "escape": (53, "\u{1b}"), "up": (126, "\u{f700}"), "down": (125, "\u{f701}"),
        "next": (121, "\u{f72d}"), "previous": (116, "\u{f72c}"),
    ]
    var keyCode: UInt16 = 0
    var text = token
    var ignoring = token
    var flags: NSEvent.ModifierFlags = []
    if let named = named[token] { (keyCode, text) = named; ignoring = text }
    else if token.hasPrefix("shift:") {
        flags = .shift
        text = String(token.dropFirst(6))
        ignoring = text
        if text == "a" { text = "A"; ignoring = "A" }
    } else if token.hasPrefix("cmd:") {
        flags = .command
        text = String(token.dropFirst(4)); ignoring = text
    }
    guard let result = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                       timestamp: 0, windowNumber: 0, context: nil, characters: text,
                                       charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: keyCode) else {
        throw TestFailure.failed("Could not make event")
    }
    return result
}

private func verifyCandidateLearning() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let settings = PreviewSettingsStore(home: home)
    for simplex in [false, true] {
        try settings.set(option: UInt32(CJX_OPT_SIMPLEX), enabled: simplex)
        try settings.set(option: UInt32(CJX_OPT_DYNAMIC_FREQUENCY), enabled: true)
        let store = PreviewLearningStore(home: home, simplex: simplex)
        func query(_ session: CompositionSession, _ client: TestClient) throws -> [String] {
            try session.handle(key: 97, client: client)
            return try session.handle(key: 32, client: client).candidates
        }
        let client = TestClient()
        let session = try CompositionSession(flags: settings.settings.flags, learningStore: store)
        try check(try query(session, client) == ["日", "曰"], "Fresh learning order")
        let selected = try session.handle(key: 50, client: client)
        try check(selected.learning == FrequencyEntry(code: "a", text: "曰", count: 1), "Selection was not learned exactly once")
        try check(try query(session, client) == ["曰", "日"], "Selected candidate did not move first")
        try session.cancel(client: client)
        let reopened = PreviewLearningStore(home: home, simplex: simplex)
        let restarted = try CompositionSession(flags: PreviewSettingsStore(home: home).settings.flags, learningStore: reopened)
        try check(try query(restarted, client) == ["曰", "日"], "Learned order lost after reopening settings/store/session")
        try restarted.cancel(client: client)
        let path = home.appendingPathComponent("Library/Application Support/CangjieX Preview/\(simplex ? "simplex-frequency" : "frequency").json")
        let before = try Data(contentsOf: path)
        try settings.set(option: UInt32(CJX_OPT_DYNAMIC_FREQUENCY), enabled: false)
        let disabled = try CompositionSession(flags: settings.settings.flags)
        try check(try query(disabled, client) == ["日", "曰"], "Disabling learning did not restore table order")
        try check(try disabled.handle(key: 50, client: client).learning == nil, "Disabled learning still recorded a selection")
        try check(try Data(contentsOf: path) == before, "Disabled learning changed saved history")
        try settings.set(option: UInt32(CJX_OPT_DYNAMIC_FREQUENCY), enabled: true)
        let enabledAgain = try CompositionSession(flags: settings.settings.flags, learningStore: PreviewLearningStore(home: home, simplex: simplex))
        try check(try query(enabledAgain, client) == ["曰", "日"], "Re-enabling learning did not restore history")
        print("PASS: \(simplex ? "Simplex" : "Cangjie") learning: selection reorders, survives restart, disabled restores table order without writing, re-enabled restores history.")
    }
}

@main
private enum PreviewTests {
    static func main() throws {
        _ = NSApplication.shared
        try verifyCandidateLearning()
        if CommandLine.arguments.contains("--learning-only") { return }
        var steps = 0
        var scenarios = 0
        for path in ["migration/baseline/cases.json", "migration/baseline/m2-cases.json", "migration/baseline/m3-live-cases.json", "migration/baseline/m3-full-cases.json", "migration/baseline/simplex-cases.json", "migration/baseline/correction-cases.json", "migration/baseline/simplex-full-cases.json"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let baseline = try JSONDecoder().decode(Baselines.self, from: data)
            for scenario in baseline.cases {
                let session = try CompositionSession(flags: baseline.profile_flags)
                let client = TestClient()
                for (index, token) in scenario.events.enumerated() {
                    let actual: EngineSnapshot
                    if token.hasPrefix("text:") {
                        actual = try session.directText(String(token.dropFirst(5)), client: client)
                    } else {
                        let (key, modifiers) = PreviewKeyMapper.translate(try event(token))
                        actual = try session.handle(key: key, modifiers: modifiers, client: client)
                    }
                    let expected = scenario.expected[index]
                    let size = expected.composing != nil ? 9 : min(9, expected.candidates.count)
                    let first = expected.page * size
                    let page = Array(expected.candidates.dropFirst(first).prefix(size))
                    try check(actual.handled == expected.handled && actual.reading == expected.reading
                              && actual.committed == expected.committed && actual.beep == expected.beep
                              && actual.visible == expected.visible && actual.page == expected.page
                              && actual.highlight == expected.highlight && actual.candidateCount == expected.candidates.count
                              && actual.candidates == page && actual.composing == (expected.composing ?? "")
                              && actual.cursor == (expected.cursor ?? 0), "Native mapping/bridge mismatch: \(scenario.id) step \(index + 1)")
                    steps += 1
                }
                scenarios += 1
            }
        }
        print("PASS: native NSEvent mapping and production bridge matched \(scenarios) scenarios / \(steps) snapshots.")

        let session = try CompositionSession()
        let client = TestClient()
        func type(_ text: String) throws {
            for byte in text.utf8 { try session.handle(key: UInt32(byte), client: client) }
        }
        try type("a")
        try check(client.view.hasMarkedText() && client.view.string == "日", "Radical was not marked")
        try session.handle(key: 32, client: client)
        try session.handle(key: 50, client: client)
        try check(client.view.string == "曰" && !client.view.hasMarkedText(), "Selection failed to replace marked text")
        try type("rvbce")
        try session.handle(key: 32, client: client)
        try check(client.view.string == "曰𨈍" && client.view.string.utf16.count == 3, "Supplementary character was truncated")
        let before = client.inserts.count
        try session.commit(client: client)
        try session.deactivate(client: client)
        try check(client.inserts.count == before, "Repeated lifecycle callback duplicated committed text")
        try type("ab")
        try session.commit(client: client)
        try check(client.view.string == "曰𨈍", "External system commit must exclude the reading buffer")
        try type("ab")
        try session.deactivate(client: client)
        try check(client.view.string == "曰𨈍日月" && !client.view.hasMarkedText(), "Deactivation did not flush the displayed reading buffer")
        try type("a")
        try session.handle(key: 32, client: client)
        try session.handle(key: UInt32(CJX_KEY_DOWN), client: client)
        try session.deactivate(client: client)
        try check(client.view.string == "曰𨈍日月日", "Deactivation chose a candidate instead of the displayed reading")
        try type("a")
        try session.handle(key: UInt32(CJX_KEY_ESCAPE), client: client)
        try check(client.view.string == "曰𨈍日月日" && !client.view.hasMarkedText(), "Escape removed committed content")
        print("PASS: real NSTextView marking, selection, Unicode commit and lifecycle cleanup.")

        for (keyCode, expected) in [(UInt16(36), CJX_KEY_RETURN), (76, CJX_KEY_RETURN), (51, CJX_KEY_BACKSPACE),
                                    (53, CJX_KEY_ESCAPE), (123, CJX_KEY_LEFT), (124, CJX_KEY_RIGHT)] {
            let (actual, _) = PreviewKeyMapper.translate(characters: nil, keyCode: keyCode, flags: [])
            try check(actual == UInt32(expected), "Special key mapping")
        }
        let (letter, flags) = PreviewKeyMapper.translate(characters: "A", keyCode: 0, flags: [.shift, .capsLock])
        try check(letter == 97 && flags == UInt32(CJX_MOD_SHIFT | CJX_MOD_CAPS_LOCK), "Case normalization")

        let settings = LegacySettings(module: ["ComposeWhileTyping": true, "ShouldCommitAtMaximumRadicalLength": true,
            "ClearReadingBufferAtCompositionError": false, "UseDynamicFrequency": true,
            "UseOverrideTable": "Punctuations-cj-halfwidth-cin"],
            loader: ["HighlightColor": "0.000000 0.478431 0.749020"])
        try check(settings.flags == 107 && settings.fontSize == 17, "Legacy settings were not preserved")
        let filteredSettings = LegacySettings(module: [:], loader: ["ActivatedOutputFilters": ["OVOFHanConvert-TC2SC"],
            "ActivatedAroundFilters": ["AssociatedPhrase"], "CandidateTextFontHeight": "nan"])
        try check(filteredSettings.flags & 384 == 384 && filteredSettings.fontSize == 17, "Legacy output filters or font validation")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preferences = temporary.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        let legacyModule: [String: Any] = ["ComposeWhileTyping": "true", "ShouldCommitAtMaximumRadicalLength": "true",
            "ClearReadingBufferAtCompositionError": "false", "UseDynamicFrequency": "true",
            "UseSpaceAsFirstCandidateSelectionKey": "false", "SendFirstCandidateWithSpaceWithOnePageList": "true",
            "UseOverrideTable": "Punctuations-cj-halfwidth-cin"]
        let legacyLoader: [String: Any] = ["ActivatedOutputFilters": ["OVOFHanConvert-TC2SC"],
            "ActivatedAroundFilters": ["AssociatedPhrase"], "HighlightColor": "0.000000 0.478431 0.749020"]
        for (domain, values) in [("com.yahoo.KeyKey.Generic-cj-cin", legacyModule), ("com.yahoo.KeyKey", legacyLoader)] {
            let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            let url = preferences.appendingPathComponent("\(domain).plist")
            try bytes.write(to: url)
            try check(LegacySettings.load(home: temporary).flags & 107 == 107, "String-valued legacy preference import")
            try check(try Data(contentsOf: url) == bytes, "Preference import wrote to the legacy domain")
        }
        try check(LegacySettings.load(home: temporary).flags == 491, "Legacy preference files did not enable the full current profile")
        let legacyDB = temporary.appendingPathComponent("Library/Application Support/Yahoo! KeyKey/Generic-cj-cin-DynamicCandidateOrder.sqlite3")
        try FileManager.default.createDirectory(at: legacyDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        try check(sqlite3_open(legacyDB.path, &database) == SQLITE_OK, "Could not create test learning database")
        try check(sqlite3_exec(database, "CREATE TABLE user_frequency(key,value,count); INSERT INTO user_frequency VALUES('a','曰',5);", nil, nil, nil) == SQLITE_OK,
                  "Could not seed test learning database")
        sqlite3_close(database)
        let beforeDB = try Data(contentsOf: legacyDB)
        let store = PreviewLearningStore(home: temporary)
        let learned = try CompositionSession(flags: settings.flags, learningStore: store)
        let learningClient = TestClient()
        try check(try learned.handle(key: 97, client: learningClient).candidates == ["曰", "日"], "Legacy learned order not imported")
        try learned.handle(key: 50, client: learningClient)
        try learned.cancel(client: learningClient)
        try check(try learned.handle(key: 97, client: learningClient).visible, "Reset discarded live settings")
        let restarted = PreviewLearningStore(home: temporary)
        try check(restarted.entries.contains(FrequencyEntry(code: "a", text: "日", count: 1)), "Preview learning did not survive restart")
        try check(try Data(contentsOf: legacyDB) == beforeDB, "Preview wrote to legacy learning database")
        let outputSession = try CompositionSession(flags: 491)
        let outputClient = TestClient()
        for byte in "oiar".utf8 { try outputSession.handle(key: UInt32(byte), client: outputClient) }
        let output = try outputSession.handle(key: 32, client: outputClient)
        try check(output.committed == "仓" && output.associated && outputClient.view.string == "仓", "Output filter / phrase hint commit")
        let insertions = outputClient.inserts.count
        try outputSession.commit(client: outputClient)
        try outputSession.deactivate(client: outputClient)
        try check(outputClient.inserts.count == insertions && !outputSession.snapshot.visible, "Lifecycle committed a phrase hint")
        print("PASS: legacy preference import, isolated learning persistence, simplified output and phrase lifecycle.")

        let screen = NSRect(x: -1600, y: -200, width: 1600, height: 1000)
        let size = NSSize(width: 224, height: 380)
        for caret in [NSRect(x: -20, y: -180, width: 1, height: 20), NSRect(x: -1590, y: 780, width: 1, height: 20)] {
            try check(screen.contains(CandidateWindow.placement(size: size, caret: caret, visibleFrame: screen)),
                      "Candidate window escaped a negative-origin display")
        }
        let window = CandidateWindow()
        var clicks: [Int] = []
        var pageDirections: [Bool] = []
        try type("a")
        let snapshot = try session.handle(key: 32, client: client)
        window.show(snapshot, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0, settings: settings,
                    choose: { clicks.append($0) }, turnPage: { pageDirections.append($0) })
        try check(window.isVisible && window.frame.width >= 168 && window.frame.width <= 372 && window.frame.height >= 70, "Candidate panel layout")
        guard let panel = NSApp.windows.first(where: { $0.title == "倉頡星 Preview 候選" && $0.isVisible }),
              let content = panel.contentView as? NSStackView else { throw TestFailure.failed("Candidate content missing") }
        try check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow, "Candidate panel can steal keyboard focus")
        let singlePageRows = content.arrangedSubviews.compactMap { $0 as? NSButton }
        try check(singlePageRows.count == 2 && content.arrangedSubviews.count == 2, "Single-page candidates showed paging controls")
        singlePageRows[1].performClick(nil)
        try check(clicks == [1], "Candidate click did not dispatch the second candidate exactly once")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            content.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            try check(content.bounds.width <= window.frame.width && content.bounds.height <= window.frame.height,
                      "Candidate content escaped the panel in \(name) appearance")
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw TestFailure.failed("Candidate render failed in \(name) appearance")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw TestFailure.failed("Candidate PNG encoding failed")
            }
            try data.write(to: URL(fileURLWithPath: "build/migration/preview/candidate-\(name).png"))
        }
        window.hide()
        try check(!window.isVisible, "Candidate panel did not hide")
        singlePageRows[1].performClick(nil)
        try check(clicks == [1], "Hidden candidate retained an active callback")

        let pagingEngine = try RustSession(flags: 107)
        var pagingSnapshot = EngineSnapshot.empty
        for byte in "ddp".utf8 { pagingSnapshot = try pagingEngine.process(key: UInt32(byte)) }
        window.show(pagingSnapshot, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0, settings: settings,
                    choose: { clicks.append($0) }, turnPage: { pageDirections.append($0) })
        let pagingFooters = content.arrangedSubviews.compactMap { $0 as? NSStackView }
        try check(pagingFooters.count == 1, "Multiple-page candidates did not show a paging footer")
        let pagingButtons = pagingFooters[0].arrangedSubviews.compactMap { $0 as? NSButton }
        try check(pagingButtons.count == 2, "Paging controls missing")
        pagingButtons[1].performClick(nil)
        pagingButtons[0].performClick(nil)
        try check(pageDirections == [true, false], "Paging button directions were reversed or repeated")
        let firstPageHeight = window.frame.height
        let paged = try pagingEngine.process(key: UInt32(CJX_KEY_PAGE_DOWN))
        window.show(paged, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0, settings: settings,
                    choose: { clicks.append($0) }, turnPage: { pageDirections.append($0) })
        try check(window.frame.height == firstPageHeight, "Paging moved the footer or resized the panel")
        let lastPageRows = content.arrangedSubviews.compactMap { $0 as? NSButton }
        try check(lastPageRows.count == paged.candidates.count && lastPageRows.count == 4, "Last page displayed stale candidates")
        lastPageRows[0].performClick(nil)
        try check(clicks == [1, 0], "Last-page click did not use a page-relative index")
        window.hide()
        pagingButtons[0].performClick(nil)
        try check(pageDirections == [true, false], "Hidden paging button retained an active callback")

        window.show(output, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0, settings: settings,
                    choose: { clicks.append($0) }, turnPage: { pageDirections.append($0) })
        let phraseRows = content.arrangedSubviews.compactMap { $0 as? NSButton }
        try check(!phraseRows.isEmpty && phraseRows.allSatisfy { $0.isEnabled }, "Phrase click selection is unavailable")
        phraseRows[0].performClick(nil)
        try check(clicks == [1, 0, 0], "Phrase click did not dispatch a page-relative selection")
        window.hide()
        print("PASS: native candidate clicks, stable paging, hidden callbacks and phrase selection.")

        for index in 0..<9 {
            let expected = Array("!@#$%^&*(".utf8)[index]
            let mapped = PreviewKeyMapper.candidateSelection(index: index, associated: true, spaceFirst: false)
            try check(mapped?.0 == UInt32(expected) && mapped?.1 == UInt32(CJX_MOD_SHIFT), "Phrase mouse mapping")
            let ordinary = PreviewKeyMapper.candidateSelection(index: index, associated: false, spaceFirst: false)
            try check(ordinary?.0 == UInt32(49 + index) && ordinary?.1 == 0, "Ordinary mouse mapping")
            let spaceFirst = PreviewKeyMapper.candidateSelection(index: index, associated: false, spaceFirst: true)
            try check(spaceFirst?.0 == (index == 0 ? 32 : UInt32(48 + index)) && spaceFirst?.1 == 0, "Space-first mouse mapping")
        }
        try check(PreviewKeyMapper.candidateSelection(index: -1, associated: true, spaceFirst: false) == nil
                  && PreviewKeyMapper.candidateSelection(index: 9, associated: true, spaceFirst: false) == nil
                  && PreviewKeyMapper.candidateSelection(index: 9, associated: false, spaceFirst: false) == nil
                  && PreviewKeyMapper.candidateSelection(index: 9, associated: false, spaceFirst: true)?.0 == 57,
                  "Mouse selection bounds")
        let phraseSession = try CompositionSession(flags: 491)
        let phraseClient = TestClient()
        for byte in "oiar".utf8 { try phraseSession.handle(key: UInt32(byte), client: phraseClient) }
        try phraseSession.handle(key: 32, client: phraseClient)
        let physicalSession = try CompositionSession(flags: 491)
        let physicalClient = TestClient()
        for byte in "oiar".utf8 { try physicalSession.handle(key: UInt32(byte), client: physicalClient) }
        try physicalSession.handle(key: 32, client: physicalClient)
        let physicalResult = try physicalSession.handle(key: 33, modifiers: UInt32(CJX_MOD_SHIFT), client: physicalClient)
        window.show(phraseSession.snapshot, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0,
                    choose: { index in
                        let mapped = PreviewKeyMapper.candidateSelection(index: index, associated: true, spaceFirst: false)!
                        try! phraseSession.handle(key: mapped.0, modifiers: mapped.1, client: phraseClient)
                    }, turnPage: { _ in })
        (content.arrangedSubviews.compactMap { $0 as? NSButton })[0].performClick(nil)
        try check(phraseClient.view.string == physicalClient.view.string && phraseClient.inserts.count == 2
                  && phraseSession.snapshot == physicalResult && !physicalResult.committed.isEmpty,
                  "Phrase click differs from Shift+1 or duplicates the original character")
        window.hide()
        try check(LegacySettings(module: [:], loader: ["CandidateTextFontHeight": 24]).fontSize == 24,
                  "Explicit font size was replaced by the new default")
        for (color, expected) in [(NSColor.yellow, NSColor.black), (.black, .white), (.white, .black)] {
            try check(CandidateWindow.selectionTextColor(on: color) == expected, "Custom highlight contrast")
        }

        func renderCandidate(_ name: String, appearance: NSAppearance.Name) throws {
            content.appearance = NSAppearance(named: appearance)
            content.layoutSubtreeIfNeeded()
            func checkChildren(_ view: NSView) throws {
                for child in view.subviews {
                    try check(view.bounds.insetBy(dx: -1, dy: -1).contains(child.frame), "Clipped native candidate control: \(name)")
                    if let field = child as? NSTextField {
                        try check(field.frame.width >= field.intrinsicContentSize.width - 1, "Clipped prompt: \(field.stringValue)")
                    }
                    try checkChildren(child)
                }
            }
            try checkChildren(content)
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                throw TestFailure.failed("Candidate render failed: \(name)")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/migration/preview/\(name).png"))
        }
        let phraseFixture = EngineSnapshot(handled: true, reading: "", committed: "", beep: false, visible: true,
            page: 0, highlight: 9, candidateCount: 36, perPage: 9, associated: true, learning: nil,
            candidates: ["帝", "熱", "症", "炎", "黃", "夏", "暑", "涼", "日"])
        window.show(phraseFixture, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0,
                    settings: settings, choose: { _ in }, turnPage: { _ in })
        let phraseHeight = window.frame.height
        try renderCandidate("candidate-phrases-light", appearance: .aqua)
        try renderCandidate("candidate-phrases-dark", appearance: .darkAqua)
        let lastPhrasePage = EngineSnapshot(handled: true, reading: "", committed: "", beep: false, visible: true,
            page: 3, highlight: 9, candidateCount: 29, perPage: 9, associated: true, learning: nil, candidates: ["帝", "熱"])
        window.show(lastPhrasePage, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0,
                    settings: settings, choose: { _ in }, turnPage: { _ in })
        try check(window.frame.height == phraseHeight, "Associated last page moved footer")
        try renderCandidate("candidate-phrases-last", appearance: .darkAqua)
        let longFixture = EngineSnapshot(handled: true, reading: "", committed: "", beep: false, visible: true,
            page: 0, highlight: 0, candidateCount: 1, perPage: 9, associated: false, learning: nil,
            candidates: [String(repeating: "長詞測試", count: 8)])
        window.show(longFixture, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0,
                    settings: LegacySettings(module: [:], loader: ["CandidateTextFontHeight": 24, "HighlightColor": "Yellow"]),
                    choose: { _ in }, turnPage: { _ in })
        try check(window.frame.width <= 372, "Long candidates grew beyond the width limit")
        try renderCandidate("candidate-long-yellow", appearance: .aqua)
        window.hide()
        print("PASS: mouse-to-Rust phrase commit, light/dark native rendering, complete prompts and custom highlight contrast.")
        let independentHome = temporary.appendingPathComponent("menu-settings")
        let independentPrefs = independentHome.appendingPathComponent("Library/Preferences")
        try FileManager.default.createDirectory(at: independentPrefs, withIntermediateDirectories: true)
        let sourcePrefs = independentPrefs.appendingPathComponent("com.yahoo.KeyKey.plist")
        let sourceBytes = try PropertyListSerialization.data(fromPropertyList: [
            "ActivatedOutputFilters": ["OVOFHanConvert-TC2SC"], "ActivatedAroundFilters": ["AssociatedPhrase"],
            "CandidateTextFontHeight": 19], format: .xml, options: 0)
        try sourceBytes.write(to: sourcePrefs)
        let independent = PreviewSettingsStore(home: independentHome)
        let settingsPath = independentHome.appendingPathComponent("Library/Application Support/CangjieX Preview/settings.json")
        try check(independent.settings.flags & 384 == 384 && independent.settings.fontSize == 19
                  && !FileManager.default.fileExists(atPath: settingsPath.path), "Read-only initial setting inheritance")
        try independent.set(option: UInt32(CJX_OPT_ASSOCIATED_PHRASES), enabled: false)
        try independent.set(option: UInt32(CJX_OPT_SIMPLIFIED_OUTPUT), enabled: false)
        try independent.set(option: UInt32(CJX_OPT_FULLWIDTH_OUTPUT), enabled: true)
        try independent.set(fontSize: 20)
        try independent.set(playErrorSound: false)
        let restartedSettings = PreviewSettingsStore(home: independentHome)
        try check(restartedSettings.settings.flags & 384 == 0 && restartedSettings.settings.flags & 512 == 512
                  && restartedSettings.settings.fontSize == 20 && !restartedSettings.settings.playErrorSound,
                  "Independent menu settings did not survive restart")
        try check(try Data(contentsOf: sourcePrefs) == sourceBytes, "Menu setting saved over legacy preferences")
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsPath.path)
        try check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Settings file permissions")
        let sourceChanged = try PropertyListSerialization.data(fromPropertyList: ["CandidateTextFontHeight": 24], format: .xml, options: 0)
        try sourceChanged.write(to: sourcePrefs)
        restartedSettings.reloadInheritedSettings()
        try check(restartedSettings.settings.fontSize == 20 && restartedSettings.settings.flags & 512 == 512,
                  "Legacy reload overwrote independent overrides")
        try sourceBytes.write(to: sourcePrefs)

        let target = TestMenuTarget()
        let menu = PreviewMenuCommand.menu(settings: independent.settings, target: target, action: #selector(TestMenuTarget.receive(_:)))
        let associatedItem = menu.items.first { $0.tag == PreviewMenuCommand.associated.rawValue }!
        let widthItem = menu.items.first { $0.tag == PreviewMenuCommand.fullwidth.rawValue }!
        try check(associatedItem.state == .off && widthItem.state == .on, "Menu checks differ from effective settings")
        for item in menu.items where item.action != nil { menu.performActionForItem(at: menu.index(of: item)) }
        try check(target.commands == [.cangjie, .simplex, .correction, .associated, .fullwidth, .simplified, .symbols, .preferences, .about], "Native menu actions missing or misrouted")
        target.receive([kIMKCommandMenuItemName as String: associatedItem])
        try check(target.commands.last == .associated && target.commands.count == 10, "IMK dictionary menu dispatch failed")
        try check(menu.items.allSatisfy { !$0.title.contains("尚未移植") }
                  && menu.items.first(where: { $0.tag == PreviewMenuCommand.cangjie.rawValue })?.state == .on,
                  "Migrated modes still unavailable or current mode unchecked")
        try check(widthItem.keyEquivalent == " " && widthItem.keyEquivalentModifierMask == [.command, .shift], "Fullwidth shortcut label")
        try check(PreviewMenuCommand.shortcut(key: 103, modifiers: UInt32(CJX_MOD_COMMAND | CJX_MOD_CONTROL)) == .simplified
                  && PreviewMenuCommand.shortcut(key: 32, modifiers: UInt32(CJX_MOD_COMMAND | CJX_MOD_SHIFT)) == .fullwidth
                  && PreviewMenuCommand.shortcut(key: 46, modifiers: UInt32(CJX_MOD_COMMAND | CJX_MOD_CONTROL)) == .symbols
                  && PreviewMenuCommand.shortcut(key: 103, modifiers: 0) == nil
                  && PreviewMenuCommand.shortcut(key: 103, modifiers: UInt32(CJX_MOD_COMMAND | CJX_MOD_CONTROL | CJX_MOD_OPTION)) == nil,
                  "Menu shortcut dispatch or modifier isolation")
        let widthSession = try RustSession(flags: independent.settings.flags)
        try check(try widthSession.process(key: 50).committed == "２", "Saved fullwidth setting did not cross Swift/Rust ABI")
        let preferencesWindow = PreviewPreferencesWindow(store: independent)
        guard let preferencesContent = preferencesWindow.window?.contentView else { throw TestFailure.failed("Preferences missing") }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        guard let nativeTabs = descendants(preferencesContent).compactMap({ $0 as? NSTabView }).first else {
            throw TestFailure.failed("Native preferences tabs missing")
        }
        nativeTabs.selectTabViewItem(at: 1)
        preferencesContent.layoutSubtreeIfNeeded()
        guard let phraseCheckbox = descendants(preferencesContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "聯想詞提示" }) else {
            throw TestFailure.failed("Phrase preference control missing")
        }
        phraseCheckbox.performClick(nil)
        try check(independent.settings.flags & 256 != 0, "Native preferences checkbox did not save")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            preferencesWindow.window?.appearance = NSAppearance(named: appearance)
            preferencesWindow.window?.orderFront(nil)
            for index in 0..<3 {
                nativeTabs.selectTabViewItem(at: index)
                preferencesContent.layoutSubtreeIfNeeded()
                preferencesWindow.window?.displayIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
                for button in descendants(nativeTabs.tabViewItems[index].view!).compactMap({ $0 as? NSButton }) {
                    try check(button.frame.width >= button.intrinsicContentSize.width - 1 && button.frame.height > 10,
                              "Preferences control has no visible layout: \(button.title)")
                }
                guard let bitmap = preferencesContent.bitmapImageRepForCachingDisplay(in: preferencesContent.bounds) else {
                    throw TestFailure.failed("Preferences rendering failed")
                }
                preferencesContent.cacheDisplay(in: preferencesContent.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/migration/preview/preferences-\(index)-\(name).png"))
            }
        }
        let controls = descendants(preferencesContent)
        let picker = controls.compactMap { $0 as? NSPopUpButton }.first { $0.itemTitles.contains("24 pt") }!
        picker.selectItem(withTitle: "24 pt")
        _ = picker.sendAction(picker.action!, to: picker.target)
        try check(independent.settings.fontSize == 24, "Native candidate font preference did not save")
        let soundCheckbox = controls.compactMap { $0 as? NSButton }.first { $0.title == "錯碼時播放提示音" }!
        soundCheckbox.performClick(nil)
        try check(independent.settings.playErrorSound, "Native sound preference did not save")
        try check(try Data(contentsOf: sourcePrefs) == sourceBytes, "Native preferences changed legacy configuration")
        nativeTabs.selectTabViewItem(at: 0)
        preferencesContent.layoutSubtreeIfNeeded()
        guard let modePicker = descendants(preferencesContent).compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles == ["倉頡", "簡易"] }) else {
            throw TestFailure.failed("Native mode picker missing")
        }
        modePicker.selectItem(at: 1)
        _ = modePicker.sendAction(modePicker.action!, to: modePicker.target)
        try check(independent.settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0, "Native mode picker did not select Simplex")
        modePicker.selectItem(at: 0)
        _ = modePicker.sendAction(modePicker.action!, to: modePicker.target)
        preferencesWindow.close()
        print("PASS: isolated settings inheritance/persistence, native menus/IMK dispatch, shortcuts, Rust fullwidth output and native preference actions/rendering.")
        try independent.set(option: UInt32(CJX_OPT_SIMPLEX), enabled: true)
        try check(independent.settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0
                  && independent.settings.flags & UInt32(CJX_OPT_COMMIT_AT_MAXIMUM) != 0
                  && independent.settings.flags & UInt32(CJX_OPT_DYNAMIC_FREQUENCY) == 0,
                  "Simplex did not inherit independent defaults")
        try independent.set(option: UInt32(CJX_OPT_COMPOSE_WHILE_TYPING), enabled: true)
        try independent.set(option: UInt32(CJX_OPT_SIMPLEX), enabled: false)
        try check(independent.settings.flags & UInt32(CJX_OPT_COMPOSE_WHILE_TYPING) == 0, "Simplex input setting leaked into Cangjie")
        try independent.set(option: UInt32(CJX_OPT_SIMPLEX), enabled: true)
        try check(independent.settings.flags & UInt32(CJX_OPT_COMPOSE_WHILE_TYPING) != 0
                  && PreviewSettingsStore(home: independentHome).settings.flags & UInt32(CJX_OPT_SIMPLEX) != 0,
                  "Simplex mode or per-mode setting lost on reload")
        let cangjieLearningPath = temporary.appendingPathComponent("Library/Application Support/CangjieX Preview/frequency.json")
        let cangjieLearningBytes = try Data(contentsOf: cangjieLearningPath)
        let simplexLearning = PreviewLearningStore(home: temporary, simplex: true)
        simplexLearning.record(FrequencyEntry(code: "a", text: "日", count: 999))
        try check(try Data(contentsOf: cangjieLearningPath) == cangjieLearningBytes
                  && PreviewLearningStore(home: temporary, simplex: true).entries.contains(FrequencyEntry(code: "a", text: "日", count: 999)),
                  "Simplex learning changed Cangjie history or was not persisted")
        let correction = try CompositionSession(flags: UInt32(CJX_OPT_BOPOMOFO_CORRECTION))
        let correctedClient = TestClient()
        let pendingCorrection = try correction.directText("𨈍ㄅㄇ", client: correctedClient)
        try check(pendingCorrection.correction && correctedClient.view.string == "𨈍ㄅㄇ"
                  && correctedClient.view.hasMarkedText() && correctedClient.selections.last?.location == 2,
                  "Correction Unicode scalar cursor was not converted to UTF-16")
        try correction.handle(key: 50, client: correctedClient)
        try check(correctedClient.view.string == "𨈍吧ㄇ" && correctedClient.inserts == ["𨈍吧ㄇ"]
                  && !correctedClient.view.hasMarkedText(), "Correction committed original plus replacement or changed more than one symbol")
        try correction.directText("ㄅ", client: correctedClient)
        try correction.commit(client: correctedClient)
        try correction.deactivate(client: correctedClient)
        try check(correctedClient.inserts == ["𨈍吧ㄇ", "ㄅ"], "System commit/deactivation lost or duplicated correction original")
        let unicodeEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "ㄅ", charactersIgnoringModifiers: "ㄅ", isARepeat: false, keyCode: 0)!
        let unicodeMapping = PreviewKeyMapper.translate(unicodeEvent)
        try check(PreviewKeyMapper.directText(characters: unicodeEvent.characters, key: unicodeMapping.0, modifiers: unicodeMapping.1) == "ㄅ"
                  && PreviewKeyMapper.directText(characters: "ㄅ", key: 0, modifiers: UInt32(CJX_MOD_COMMAND)) == nil,
                  "Unicode input mapping or shortcut isolation")
        try correction.directText("𨈍ㄅㄇ", client: correctedClient)
        let correctionWindow = CandidateWindow()
        correctionWindow.show(pendingCorrection, caret: NSRect(x: 300, y: 400, width: 1, height: 20), windowLevel: 0,
            settings: LegacySettings(module: ["UseSpaceAsFirstCandidateSelectionKey": true], loader: [:]),
            choose: { index in
                let mapped = PreviewKeyMapper.candidateSelection(index: index, associated: false, spaceFirst: false)!
                try! correction.handle(key: mapped.0, client: correctedClient)
            }, turnPage: { _ in })
        guard let correctionPanel = NSApp.windows.first(where: { $0.title == "倉頡星 Preview 候選" && $0.isVisible }),
              let correctionContent = correctionPanel.contentView as? NSStackView else { throw TestFailure.failed("Correction candidates missing") }
        let correctionRows = correctionContent.arrangedSubviews.compactMap { $0 as? NSButton }
        try check(correctionRows[0].accessibilityLabel()?.contains("1，") == true,
                  "Cangjie space-first preference altered correction selection labels")
        correctionRows[1].performClick(nil)
        try check(correctedClient.inserts.last == "𨈍吧ㄇ", "Correction mouse selection used a normal space-first index")
        correctionWindow.hide()
        print("PASS: per-mode settings and learning isolation, correction NSTextView replacement, UTF-16 caret and lossless lifecycle.")
        let plistData = try Data(contentsOf: URL(fileURLWithPath: "migration/preview/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let identifier = "io.github.geekstek.inputmethod.CangjieXPreview"
        try check(plist["CFBundleIdentifier"] as? String == identifier
                  && plist["TISInputSourceID"] as? String == identifier
                  && plist["InputMethodConnectionName"] as? String == identifier + "_Connection",
                  "Preview identity must remain independent of legacy")
        let className = plist["InputMethodServerControllerClass"] as? String ?? ""
        try check(NSClassFromString(className)?.isSubclass(of: IMKInputController.self) == true,
                  "IMK Objective-C controller class is missing")
        print("PASS: candidate panel layout/placement/hiding and IMK runtime class registration.")
    }
}
