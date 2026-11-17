import Foundation

enum SessionProbeError: Error {
    case failed(String)
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SessionProbeError.failed(message) }
}

struct Frame: Decodable, Equatable {
    let event: String
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

struct Scenario: Decodable {
    let id: String
    let events: [String]
    let expected: [Frame]
}

struct Baselines: Decodable {
    let profile_flags: UInt32?
    let cases: [Scenario]
}

func eventCode(_ token: String) throws -> (UInt32, UInt32) {
    let keys: [String: UInt32] = [
        "space": 32, "return": UInt32(CJX_KEY_RETURN), "backspace": UInt32(CJX_KEY_BACKSPACE),
        "escape": UInt32(CJX_KEY_ESCAPE), "up": UInt32(CJX_KEY_UP), "down": UInt32(CJX_KEY_DOWN),
        "previous": UInt32(CJX_KEY_PAGE_UP), "next": UInt32(CJX_KEY_PAGE_DOWN),
        "left": UInt32(CJX_KEY_LEFT), "right": UInt32(CJX_KEY_RIGHT), "other": UInt32(CJX_KEY_OTHER),
    ]
    if let code = keys[token] { return (code, 0) }
    let prefixes: [(String, UInt32)] = [
        ("cmd:", UInt32(CJX_MOD_COMMAND)), ("ctrl:", UInt32(CJX_MOD_CONTROL)),
        ("option:", UInt32(CJX_MOD_OPTION)), ("shift:", UInt32(CJX_MOD_SHIFT)),
    ]
    for (prefix, modifiers) in prefixes where token.hasPrefix(prefix) {
        let bytes = Array(token.dropFirst(prefix.count).utf8)
        guard bytes.count == 1 else { throw SessionProbeError.failed("Invalid event \(token)") }
        return (UInt32(bytes[0]), modifiers)
    }
    let bytes = Array(token.utf8)
    guard bytes.count == 1 else { throw SessionProbeError.failed("Unknown event \(token)") }
    return (UInt32(bytes[0]), 0)
}

func readUTF8(_ bytes: UnsafePointer<UInt8>?, _ length: Int) throws -> String {
    guard let bytes, let text = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
        throw SessionProbeError.failed("Invalid snapshot UTF-8")
    }
    return text
}

func readComposing(_ snapshot: OpaquePointer) throws -> String {
    var length = 0
    let bytes = cjx_snapshot_text(snapshot, UInt32(CJX_TEXT_COMPOSING), &length)
    return try readUTF8(bytes, length)
}

func readFrame(_ snapshot: OpaquePointer, event: String, composingFields: Bool = false) throws -> Frame {
    var info = CjxSnapshotInfo()
    try require(cjx_snapshot_info(snapshot, &info) == 0, "Snapshot info failed")
    var length = 0
    let readingBytes = cjx_snapshot_text(snapshot, UInt32(CJX_TEXT_READING), &length)
    let reading = try readUTF8(readingBytes, length)
    let committedBytes = cjx_snapshot_text(snapshot, UInt32(CJX_TEXT_COMMITTED), &length)
    let committed = try readUTF8(committedBytes, length)
    let candidates = try (0..<info.candidate_count).map { index in
        let bytes = cjx_snapshot_candidate(snapshot, index, &length)
        return try readUTF8(bytes, length)
    }
    try require(cjx_snapshot_candidate(snapshot, info.candidate_count, &length) == nil && length == 0,
                "Snapshot candidate bounds failed")
    return Frame(event: event, handled: info.handled != 0, reading: reading, committed: committed,
                 beep: info.beep != 0, visible: info.visible != 0, page: info.page,
                 highlight: info.highlight, candidates: candidates,
                 composing: composingFields ? try readComposing(snapshot) : nil,
                 cursor: composingFields ? info.cursor : nil)
}

final class EngineSession {
    let handle: OpaquePointer
    let composingFields: Bool

    init(flags: UInt32? = nil) throws {
        composingFields = (flags ?? 0) & UInt32(CJX_OPT_BOPOMOFO_CORRECTION) != 0
        var handle: OpaquePointer?
        let status = flags.map { cjx_session_new_configured($0, &handle) } ?? cjx_session_new(&handle)
        guard status == 0, let handle else {
            throw SessionProbeError.failed("Session creation failed")
        }
        self.handle = handle
    }

    deinit { cjx_session_free(handle) }

    func rawEvent(_ token: String) throws -> OpaquePointer {
        if token.hasPrefix("text:") {
            let bytes = Array(token.dropFirst(5).utf8) + [0]
            var pointer: OpaquePointer?
            let status = bytes.withUnsafeBufferPointer { cjx_session_direct_text(handle, $0.baseAddress, $0.count - 1, &pointer) }
            guard status == 0, let pointer else { throw SessionProbeError.failed("Direct text failed") }
            return pointer
        }
        let (code, modifiers) = try eventCode(token)
        var snapshot: OpaquePointer?
        guard cjx_session_handle(handle, code, modifiers, &snapshot) == 0, let snapshot else {
            throw SessionProbeError.failed("Event failed: \(token)")
        }
        return snapshot
    }

    func event(_ token: String) throws -> Frame {
        let snapshot = try rawEvent(token)
        defer { cjx_snapshot_free(snapshot) }
        return try readFrame(snapshot, event: token, composingFields: composingFields)
    }

    func reset() throws {
        try require(cjx_session_reset(handle) == 0, "Session reset failed")
    }
}

do {
    guard CommandLine.arguments.count >= 2 else {
        throw SessionProbeError.failed("usage: swift-session-probe <baseline.json>...")
    }
    var scenarioCount = 0
    var stepCount = 0
    for path in CommandLine.arguments.dropFirst() {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let baseline = try JSONDecoder().decode(Baselines.self, from: data)
        for scenario in baseline.cases {
            try require(scenario.events.count == scenario.expected.count, "Invalid scenario \(scenario.id)")
            let session = try EngineSession(flags: baseline.profile_flags)
            for (index, token) in scenario.events.enumerated() {
                let actual = try session.event(token)
                let expected = scenario.expected[index]
                try require(actual == expected, "\(scenario.id) step \(index + 1):\nexpected \(expected)\nactual \(actual)")
                stepCount += 1
            }
            scenarioCount += 1
        }
    }
    print("PASS: Swift → Rust state machine matched \(scenarioCount) reference scenarios / \(stepCount) snapshots.")

    let first = try EngineSession()
    let second = try EngineSession()
    _ = try first.event("a")
    for token in ["cmd:a", "ctrl:a", "option:a"] {
        let frame = try first.event(token)
        try require(!frame.handled && frame.reading == "日" && frame.committed.isEmpty, "Shortcut consumed input")
    }
    for (code, modifiers) in [(UInt32(0xffff), UInt32(0)), (UInt32(32), UInt32(32))] {
        var snapshot: OpaquePointer?
        try require(cjx_session_handle(first.handle, code, modifiers, &snapshot) == -1 && snapshot == nil,
                    "Invalid event accepted")
    }
    try require(try first.event("space").candidates == ["日", "曰"], "Rejected events changed state")
    _ = try second.event("a")
    try first.reset()
    try first.reset()
    let resetFrame = try first.event("other")
    try require(!resetFrame.handled && !resetFrame.visible && resetFrame.reading.isEmpty, "Reset did not cancel input")
    try require(try second.event("space").candidates == ["日", "曰"], "Reset affected a different session")

    var owner: EngineSession? = try EngineSession()
    let retained = try owner!.rawEvent("a")
    _ = try owner!.event("space")
    owner = nil
    try require(try readFrame(retained, event: "a").reading == "日", "Snapshot did not outlive session")
    cjx_snapshot_free(retained)

    for _ in 0..<1000 {
        let session = try EngineSession()
        _ = try session.event("a")
        _ = try session.event("space")
        try require(try session.event("2").committed == "曰", "Repeated session lifetime failed")
    }
    cjx_session_free(nil)
    cjx_snapshot_free(nil)
    print("PASS: session isolation, reset, shortcut passthrough, invalid events, retained snapshots and 1,000 session lifetimes checked.")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
