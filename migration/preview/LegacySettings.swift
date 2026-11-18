import AppKit
import Foundation
import os

struct LegacySettings {
    let flags: UInt32
    let fontSize: CGFloat
    let highlight: NSColor
    let playErrorSound: Bool

    init(module: [String: Any], loader: [String: Any], simplex: Bool = false) {
        func enabled(_ key: String, _ fallback: Bool) -> Bool {
            guard let value = module[key] else { return fallback }
            if let bool = value as? Bool { return bool }
            return (value as? String).map { ["true", "1", "yes"].contains($0.lowercased()) } ?? fallback
        }
        let options: [(String, Bool, Int)] = [
            ("ComposeWhileTyping", false, CJX_OPT_COMPOSE_WHILE_TYPING),
            ("ShouldCommitAtMaximumRadicalLength", simplex, CJX_OPT_COMMIT_AT_MAXIMUM),
            ("ClearReadingBufferAtCompositionError", true, CJX_OPT_CLEAR_ON_ERROR),
            ("UseDynamicFrequency", !simplex, CJX_OPT_DYNAMIC_FREQUENCY),
            ("UseSpaceAsFirstCandidateSelectionKey", false, CJX_OPT_SPACE_SELECTS_FIRST),
            ("SendFirstCandidateWithSpaceWithOnePageList", !simplex, CJX_OPT_SPACE_SELECTS_ONE_PAGE),
            ("UseDailyCharacters", true, CJX_OPT_DAILY_CHARACTERS),
        ]
        var flags = options.reduce(UInt32(0)) { enabled($1.0, $1.1) ? $0 | UInt32($1.2) : $0 }
        if module["UseOverrideTable"] as? String == "Punctuations-cj-halfwidth-cin" {
            flags |= UInt32(CJX_OPT_HALFWIDTH_PUNCTUATION)
        }
        if (loader["ActivatedOutputFilters"] as? [String])?.contains("OVOFHanConvert-TC2SC") == true {
            flags |= UInt32(CJX_OPT_SIMPLIFIED_OUTPUT)
        }
        if (loader["ActivatedOutputFilters"] as? [String])?.contains("OVOFFullWidthCharacter") == true {
            flags |= UInt32(CJX_OPT_FULLWIDTH_OUTPUT)
        }
        if (loader["ActivatedAroundFilters"] as? [String])?.contains("AssociatedPhrase") == true {
            flags |= UInt32(CJX_OPT_ASSOCIATED_PHRASES)
        }
        if simplex { flags |= UInt32(CJX_OPT_SIMPLEX) }
        if (loader["ActivatedAroundFilters"] as? [String])?.contains("OVAFBopomofoCorrection") == true {
            flags |= UInt32(CJX_OPT_BOPOMOFO_CORRECTION)
        }
        self.flags = flags
        let height = (loader["CandidateTextFontHeight"] as? NSNumber)?.doubleValue
            ?? Double(loader["CandidateTextFontHeight"] as? String ?? "") ?? 17
        fontSize = CGFloat(height.isFinite ? min(96, max(16, height)) : 17)
        let colors: [String: NSColor] = ["Default": .purple, "Purple": .purple,
            "Green": NSColor(calibratedRed: 0.23, green: 0.68, blue: 0.12, alpha: 1),
            "Yellow": .yellow, "Red": NSColor(calibratedRed: 0.75, green: 0, blue: 0.16, alpha: 1)]
        let color = loader["HighlightColor"] as? String ?? "Default"
        let components = color.split(separator: " ").compactMap { Double($0) }
        if components.count == 3 && components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) {
            highlight = NSColor(calibratedRed: components[0], green: components[1], blue: components[2], alpha: 1)
        } else { highlight = colors[color] ?? .purple }
        playErrorSound = (loader["ShouldPlaySoundOnTypingError"] as? Bool) ?? true
    }

    init(base: LegacySettings, enabled: UInt32, disabled: UInt32, fontSize: Double?, playErrorSound: Bool?) {
        flags = (base.flags | (enabled & 8191)) & ~(disabled & 8191)
        self.fontSize = fontSize.flatMap { $0.isFinite ? CGFloat(min(96, max(16, $0))) : nil } ?? base.fontSize
        highlight = base.highlight
        self.playErrorSound = playErrorSound ?? base.playErrorSound
    }

    static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, simplex: Bool = false) -> LegacySettings {
        func read(_ domain: String) -> [String: Any] {
            let url = home.appendingPathComponent("Library/Preferences/\(domain).plist")
            guard let data = try? Data(contentsOf: url),
                  let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return [:] }
            return value as? [String: Any] ?? [:]
        }
        // Read only. Preview never writes to the old IME's preference domains.
        return LegacySettings(module: read(simplex ? "com.yahoo.KeyKey.Generic-simplex-cin" : "com.yahoo.KeyKey.Generic-cj-cin"), loader: read("com.yahoo.KeyKey"), simplex: simplex)
    }
}

final class PreviewLearningStore {
    static let shared = PreviewLearningStore()
    static let simplex = PreviewLearningStore(simplex: true)
    private let url: URL
    private(set) var entries: [FrequencyEntry] = []
    private let logger = Logger(subsystem: "io.github.geekstek.inputmethod.CangjieXPreview", category: "Learning")

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, simplex: Bool = false) {
        url = home.appendingPathComponent("Library/Application Support/CangjieX Preview/\(simplex ? "simplex-frequency" : "frequency").json")
        if FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([FrequencyEntry].self, from: data) {
                entries = rows.filter { $0.isValid }
            }
            return
        }
        let legacy = home.appendingPathComponent("Library/Application Support/Yahoo! KeyKey/Generic-\(simplex ? "simplex" : "cj")-cin-DynamicCandidateOrder.sqlite3")
        var database: OpaquePointer?
        guard sqlite3_open_v2(legacy.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT key,value,count FROM user_frequency ORDER BY rowid", -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let code = sqlite3_column_text(statement, 0), let text = sqlite3_column_text(statement, 1) else { continue }
            let count = sqlite3_column_int64(statement, 2)
            if count > 0 {
                let row = FrequencyEntry(code: String(cString: code), text: String(cString: text), count: UInt64(count))
                if row.isValid { entries.append(row) }
            }
        }
        persist()
    }

    func record(_ row: FrequencyEntry) {
        guard row.isValid else { return }
        if let index = entries.firstIndex(where: { $0.code == row.code && $0.text == row.text }) { entries[index] = row }
        else { entries.append(row) }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Never log codes, selected text or learned entries.
            logger.error("Could not save Preview learned order")
        }
    }
}
