import Foundation

enum EngineError: Error {
    case status(Int32)
    case invalidSnapshot
}

struct FrequencyEntry: Codable, Equatable {
    let code: String
    let text: String
    let count: UInt64
    var isValid: Bool {
        (1...5).contains(code.utf8.count) && code.utf8.allSatisfy { (33...126).contains($0) }
            && !text.isEmpty && text.utf8.count <= 1024 && count > 0
    }
}

struct EngineSnapshot: Equatable {
    let handled: Bool
    let reading: String
    let committed: String
    let beep: Bool
    let visible: Bool
    let page: Int
    let highlight: Int
    let candidateCount: Int
    let perPage: Int
    let associated: Bool
    let learning: FrequencyEntry?
    // Only the visible page crosses the bridge; wildcard lists can be large.
    let candidates: [String]
    var composing = ""
    var cursor = 0
    var correction = false
    var markedText: String { composing.isEmpty ? reading : composing }
    var selectionLocation: Int {
        composing.isEmpty ? reading.utf16.count : composing.unicodeScalars.prefix(cursor).reduce(0) { $0 + ($1.value > 0xffff ? 2 : 1) }
    }

    static let empty = EngineSnapshot(handled: false, reading: "", committed: "", beep: false,
                                      visible: false, page: 0, highlight: 0, candidateCount: 0, perPage: 9, associated: false, learning: nil, candidates: [])
}

final class RustSession {
    private let handle: OpaquePointer

    init(flags: UInt32? = nil, frequencies: [FrequencyEntry] = []) throws {
        var pointer: OpaquePointer?
        let status = flags.map { cjx_session_new_configured($0, &pointer) } ?? cjx_session_new(&pointer)
        guard status == 0, let pointer else { throw EngineError.status(status) }
        handle = pointer
        for row in frequencies where row.isValid {
            let code = Array(row.code.utf8), text = Array(row.text.utf8)
            let status = code.withUnsafeBufferPointer { code in
                text.withUnsafeBufferPointer { text in
                    cjx_session_set_frequency(pointer, code.baseAddress, code.count, text.baseAddress, text.count, row.count)
                }
            }
            guard status == 0 else { throw EngineError.status(status) }
        }
    }

    deinit { cjx_session_free(handle) }

    func reset() throws {
        let status = cjx_session_reset(handle)
        guard status == 0 else { throw EngineError.status(status) }
    }

    func process(key: UInt32, modifiers: UInt32 = 0) throws -> EngineSnapshot {
        var pointer: OpaquePointer?
        let status = cjx_session_handle(handle, key, modifiers, &pointer)
        guard status == 0, let pointer else { throw EngineError.status(status) }
        return try decodeSnapshot(pointer)
    }

    func directText(_ text: String) throws -> EngineSnapshot {
        let bytes = Array(text.utf8) + [0]
        var pointer: OpaquePointer?
        let status = bytes.withUnsafeBufferPointer { cjx_session_direct_text(handle, $0.baseAddress, $0.count - 1, &pointer) }
        guard status == 0, let pointer else { throw EngineError.status(status) }
        return try decodeSnapshot(pointer)
    }

    private func decodeSnapshot(_ pointer: OpaquePointer) throws -> EngineSnapshot {
        defer { cjx_snapshot_free(pointer) }
        var info = CjxSnapshotInfo()
        guard cjx_snapshot_info(pointer, &info) == 0 else { throw EngineError.invalidSnapshot }
        func text(_ field: UInt32) throws -> String {
            var length = 0
            let bytes = cjx_snapshot_text(pointer, field, &length)
            return try Self.decode(bytes, length: length)
        }
        var candidates: [String] = []
        if info.candidate_count > 0 {
            let pageSize = info.per_page
            guard pageSize > 0 && pageSize <= 10 else { throw EngineError.invalidSnapshot }
            guard info.page < (info.candidate_count + pageSize - 1) / pageSize else {
                throw EngineError.invalidSnapshot
            }
            let first = info.page * pageSize
            let end = min(first + pageSize, info.candidate_count)
            for index in first..<end {
                var length = 0
                let bytes = cjx_snapshot_candidate(pointer, index, &length)
                candidates.append(try Self.decode(bytes, length: length))
            }
            guard info.associated != 0 || info.highlight < candidates.count else { throw EngineError.invalidSnapshot }
        }
        let count = cjx_snapshot_learning_count(pointer)
        let learning = count == 0 ? nil : try FrequencyEntry(code: text(UInt32(CJX_TEXT_LEARNED_CODE)),
            text: text(UInt32(CJX_TEXT_LEARNED_VALUE)), count: count)
        return try EngineSnapshot(handled: info.handled != 0, reading: text(UInt32(CJX_TEXT_READING)),
                                  committed: text(UInt32(CJX_TEXT_COMMITTED)), beep: info.beep != 0,
                                  visible: info.visible != 0, page: info.page, highlight: info.highlight,
                                  candidateCount: info.candidate_count, perPage: info.per_page, associated: info.associated != 0, learning: learning, candidates: candidates,
                                  composing: text(UInt32(CJX_TEXT_COMPOSING)), cursor: info.cursor, correction: info.correction != 0)
    }

    private static func decode(_ bytes: UnsafePointer<UInt8>?, length: Int) throws -> String {
        guard let bytes, let text = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            throw EngineError.invalidSnapshot
        }
        return text
    }
}
