import AppKit

protocol CompositionClient {
    func mark(_ text: String, selection: NSRange)
    func insert(_ text: String)
}

final class CompositionSession {
    private let engine: RustSession
    private var ownsMarkedText = false
    private(set) var snapshot = EngineSnapshot.empty

    private let learningStore: PreviewLearningStore?
    init(flags: UInt32? = nil, learningStore: PreviewLearningStore? = nil) throws {
        self.learningStore = learningStore
        engine = try RustSession(flags: flags, frequencies: learningStore?.entries ?? [],
            characterCoverage: (flags ?? 0) & UInt32(CJX_OPT_DAILY_CHARACTERS) != 0 ? SystemCharacterCoverage.bitmap : nil)
    }

    @discardableResult
    func handle(key: UInt32, modifiers: UInt32 = 0, client: CompositionClient) throws -> EngineSnapshot {
        try apply(engine.process(key: key, modifiers: modifiers), client: client)
    }

    @discardableResult
    func directText(_ text: String, client: CompositionClient) throws -> EngineSnapshot {
        try apply(engine.directText(text), client: client)
    }

    private func apply(_ next: EngineSnapshot, client: CompositionClient) throws -> EngineSnapshot {
        snapshot = next
        if let row = next.learning { learningStore?.record(row) }
        guard next.handled else { return next }
        if !next.committed.isEmpty {
            client.insert(next.committed)
            ownsMarkedText = false
        }
        if !next.markedText.isEmpty {
            client.mark(next.markedText, selection: NSRange(location: next.selectionLocation, length: 0))
            ownsMarkedText = true
        } else if ownsMarkedText {
            client.mark("", selection: NSRange(location: 0, length: 0))
            ownsMarkedText = false
        }
        return next
    }

    // The legacy IMK external commit only flushes composing text, excluding
    // the reading buffer. KeyKey's own deactivation flushes the displayed buffer.
    func commit(client: CompositionClient) throws {
        if snapshot.correction { try handle(key: UInt32(CJX_KEY_ESCAPE), client: client) }
        try cancel(client: client)
    }

    func deactivate(client: CompositionClient) throws {
        if snapshot.correction { try handle(key: UInt32(CJX_KEY_ESCAPE), client: client) }
        if ownsMarkedText && !snapshot.reading.isEmpty {
            client.insert(snapshot.reading)
            ownsMarkedText = false
        }
        try cancel(client: client)
    }

    func cancel(client: CompositionClient) throws {
        try engine.reset()
        if ownsMarkedText { client.mark("", selection: NSRange(location: 0, length: 0)) }
        ownsMarkedText = false
        snapshot = .empty
    }
}

enum PreviewKeyMapper {
    static func candidateSelection(index: Int, associated: Bool, spaceFirst: Bool) -> (UInt32, UInt32)? {
        if associated {
            let shifted = Array("!@#$%^&*(".utf8)
            guard shifted.indices.contains(index) else { return nil }
            return (UInt32(shifted[index]), UInt32(CJX_MOD_SHIFT))
        }
        guard (0..<(spaceFirst ? 10 : 9)).contains(index) else { return nil }
        return (spaceFirst ? (index == 0 ? 32 : UInt32(48 + index)) : UInt32(49 + index), 0)
    }

    static func directText(characters: String?, key: UInt32, modifiers: UInt32) -> String? {
        guard key == UInt32(CJX_KEY_OTHER), modifiers & UInt32(CJX_MOD_COMMAND | CJX_MOD_CONTROL | CJX_MOD_OPTION) == 0,
              let characters, !characters.isEmpty, characters.utf8.count <= 4096,
              characters.unicodeScalars.allSatisfy({ $0.value >= 32 && !(0x7f...0x9f).contains($0.value) }) else { return nil }
        return characters
    }

    static func translate(characters: String?, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> (UInt32, UInt32) {
        let keys: [UInt16: UInt32] = [
            36: UInt32(CJX_KEY_RETURN), 76: UInt32(CJX_KEY_RETURN),
            51: UInt32(CJX_KEY_BACKSPACE), 53: UInt32(CJX_KEY_ESCAPE),
            126: UInt32(CJX_KEY_UP), 125: UInt32(CJX_KEY_DOWN),
            116: UInt32(CJX_KEY_PAGE_UP), 121: UInt32(CJX_KEY_PAGE_DOWN),
            123: UInt32(CJX_KEY_LEFT), 124: UInt32(CJX_KEY_RIGHT),
        ]
        let key: UInt32
        if let special = keys[keyCode] {
            key = special
        } else if let characters, characters.utf8.count == 1, let byte = characters.utf8.first,
                  byte >= 32 && byte <= 126 {
            // Rust applies Shift/Caps Lock itself. NSEvent's "ignoring"
            // characters can still include Shift, so normalize letters here.
            key = UInt32((65...90).contains(byte) ? byte + 32 : byte)
        } else {
            key = UInt32(CJX_KEY_OTHER)
        }
        var modifiers: UInt32 = 0
        if flags.contains(.shift) { modifiers |= UInt32(CJX_MOD_SHIFT) }
        if flags.contains(.command) { modifiers |= UInt32(CJX_MOD_COMMAND) }
        if flags.contains(.control) { modifiers |= UInt32(CJX_MOD_CONTROL) }
        if flags.contains(.option) { modifiers |= UInt32(CJX_MOD_OPTION) }
        if flags.contains(.capsLock) { modifiers |= UInt32(CJX_MOD_CAPS_LOCK) }
        return (key, modifiers)
    }

    static func translate(_ event: NSEvent) -> (UInt32, UInt32) {
        translate(characters: event.characters, keyCode: event.keyCode, flags: event.modifierFlags)
    }
}
