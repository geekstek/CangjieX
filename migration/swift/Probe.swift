import Foundation

enum ProbeError: Error {
    case failed(String)
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ProbeError.failed(message) }
}

func lookup(_ code: String) throws -> [String] {
    let bytes = Array(code.utf8)
    var handle: OpaquePointer?
    let status = bytes.withUnsafeBufferPointer { buffer in
        cjx_lookup(buffer.baseAddress, buffer.count, &handle)
    }
    guard status == 0, let handle else {
        throw ProbeError.failed("Rust lookup failed: \(code), status \(status)")
    }
    defer { cjx_result_free(handle) }
    var missingLength = 100
    try require(
        cjx_result_candidate(handle, cjx_result_count(handle), &missingLength) == nil && missingLength == 0,
        "Out-of-range candidate was not rejected"
    )
    return try (0..<cjx_result_count(handle)).map { index in
        var length = 0
        guard let pointer = cjx_result_candidate(handle, index, &length) else {
            throw ProbeError.failed("Missing candidate \(index) for \(code)")
        }
        let buffer = UnsafeBufferPointer(start: pointer, count: length)
        guard let text = String(bytes: buffer, encoding: .utf8) else {
            throw ProbeError.failed("Invalid UTF-8 from Rust")
        }
        return text
    }
}

do {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeError.failed("usage: swift-rust-probe <cangjie.tsv>")
    }
    let checks: [(String, [String])] = [
        ("a", ["日", "曰"]),
        ("A", ["日", "曰"]),
        ("'", ["、", "、", "′", "‘", "’", "‵"]),
        ("%", ["％"]),
        ("rvbce", ["𨈍"]),
        ("mfmff", ["厵"]),
        ("aaaaa", []),
    ]
    for (code, expected) in checks {
        let actual = try lookup(code)
        try require(actual == expected, "Candidate order/content differs for \(code)")
        print("Swift → Rust \(code): \(actual.joined(separator: " / "))")
    }
    let supplementary = try lookup("rvbce")[0]
    try require(supplementary.utf8.count == 4, "Supplementary UTF-8 length")
    try require(supplementary.utf16.count == 2, "Supplementary UTF-16 range")

    for code in ["", "abcdef", "日", "a\0", "a b"] {
        var handle: OpaquePointer?
        let status = Array(code.utf8).withUnsafeBufferPointer { buffer in
            cjx_lookup(buffer.baseAddress, buffer.count, &handle)
        }
        try require(status == -1 && handle == nil, "Invalid input accepted: \(code)")
    }
    try require(cjx_result_count(nil) == 0, "Null result count")
    var length = 100
    try require(cjx_result_candidate(nil, 0, &length) == nil && length == 0, "Null candidate")
    cjx_result_free(nil)

    for _ in 0..<1000 {
        try require(try lookup("a") == ["日", "曰"], "Repeated allocation/free")
    }

    let table = try String(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), encoding: .utf8)
    var expectedTable: [String: [String]] = [:]
    var entryCount = 0
    for line in table.split(separator: "\n") {
        let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        try require(fields.count == 2, "Malformed TSV row")
        expectedTable[String(fields[0]), default: []].append(String(fields[1]))
        entryCount += 1
    }
    try require(entryCount == 82_873 && expectedTable.count == 65_732, "Incomplete reference table")
    for (code, expected) in expectedTable {
        try require(try lookup(code) == expected, "Full-table mismatch for \(code)")
    }
    print("PASS: Swift → Rust matched all \(entryCount) entries / \(expectedTable.count) codes, preserving order and duplicates.")
    print("PASS: Unicode, errors, bounds and 1,000 result lifetimes checked.")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
    exit(1)
}
