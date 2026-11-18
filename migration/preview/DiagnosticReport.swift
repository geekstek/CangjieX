import AppKit
import Carbon

enum DiagnosticReport {
    private final class Capture {
        let lock = NSLock()
        var bytes = Data()
        var overflow = false
        func append(_ chunk: Data) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if bytes.count + chunk.count <= 1024 * 1024 { bytes.append(chunk) } else { overflow = true }
            return !overflow
        }
    }
    struct SystemSignal: Codable {
        enum Kind: String, Codable { case missingEndpoint, invalidEndpoint, endpointPublished }
        let time: String
        let kind: Kind
        let ownProcess: Bool
    }
    struct Crash: Codable {
        enum Kind: String, Codable { case badAccess, crash, guardViolation, breakpoint, resource, badInstruction, unknown }
        enum TimeSource: String, Codable { case report, fileMetadata }
        let time: Date
        let kind: Kind
        var role: DiagnosticRecord.Role? = nil
        var version: String? = nil
        var build: String? = nil
        var timeSource: TimeSource? = nil
        var pid: Int32? = nil
    }
    struct Report: Codable {
        let schema: Int
        let created: Date
        let macOS: String
        let installed: RuntimeBuildIdentity?
        let running: RuntimeVersionReply?
        let processIDs: [Int32]
        let state: DiagnosticState
        let records: [DiagnosticRecord]
        let systemSignals: [SystemSignal]
        let systemLogAvailable: Bool
        let crashes: [Crash]
        let manualTypingVerified: Bool
    }

    static func signals(from data: Data) -> [SystemSignal] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.suffix(500).compactMap { row in
            guard let message = row["eventMessage"] as? String, let time = row["timestamp"] as? String,
                  time.count < 50, time.unicodeScalars.allSatisfy({ "0123456789-+: .TZ".unicodeScalars.contains($0) }) else { return nil }
            let kind: SystemSignal.Kind
            if message.contains("NO Endpoint") { kind = .missingEndpoint }
            else if message.contains("Endpoint Invalid") { kind = .invalidEndpoint }
            else if message.contains("setIMKXPCEndpoint:") { kind = .endpointPublished }
            else { return nil }
            let own = (row["processImagePath"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent == "CangjieXPreview" } ?? false
            return SystemSignal(time: time, kind: kind, ownProcess: own)
        }
    }

    // Only normalized endpoint signals leave this bounded in-memory collector, never raw system log messages.
    static func systemSignals() -> ([SystemSignal], Bool) {
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        task.arguments = ["show", "--last", "5m", "--info", "--style", "json", "--predicate",
            "(process == \"imklaunchagent\" OR process == \"CangjieXPreview\") AND (eventMessage CONTAINS \"NO Endpoint\" OR eventMessage CONTAINS \"Endpoint Invalid\" OR eventMessage CONTAINS \"setIMKXPCEndpoint:\")"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return ([], false) }
        let done = DispatchGroup(), capture = Capture()
        done.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 4096)
                if chunk.isEmpty { break }
                if !capture.append(chunk) { task.terminate(); break }
            }
            done.leave()
        }
        guard done.wait(timeout: .now() + 5) == .success else { task.terminate(); return ([], false) }
        guard exited.wait(timeout: .now() + 1) == .success else { task.terminate(); return ([], false) }
        capture.lock.lock(); defer { capture.lock.unlock() }
        guard !capture.overflow, task.terminationStatus == 0 else { return ([], false) }
        return (signals(from: capture.bytes), true)
    }

    static func crashes(home: URL) -> [Crash] {
        let root = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])) ?? []
        let kinds: [String: Crash.Kind] = ["EXC_BAD_ACCESS": .badAccess, "EXC_CRASH": .crash, "EXC_GUARD": .guardViolation,
                                           "EXC_BREAKPOINT": .breakpoint, "EXC_RESOURCE": .resource, "EXC_BAD_INSTRUCTION": .badInstruction]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS Z"
        formatter.isLenient = false
        func date(_ value: Any?) -> Date? {
            guard let value = value as? String, value.count <= 64,
                  value.unicodeScalars.allSatisfy({ "0123456789-+: .".unicodeScalars.contains($0) }) else { return nil }
            return formatter.date(from: value)
        }
        func version(_ value: Any?) -> String? {
            guard let value = value as? String, value.count <= 32,
                  value.range(of: "^[0-9]+(?:\\.[0-9]+){0,3}$", options: .regularExpression) != nil else { return nil }
            return value
        }
        let summaries: [Crash] = files.filter { ($0.lastPathComponent.hasPrefix("CangjieXPreview-") || $0.lastPathComponent.hasPrefix("CangjieXMaintenance-")) && $0.pathExtension == "ips" }
            .compactMap { file in
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink == false, values.isRegularFile == true, let size = values.fileSize, size < 2 * 1024 * 1024,
                      let time = values.contentModificationDate, let bytes = try? Data(contentsOf: file),
                      let separator = bytes.firstIndex(of: 10),
                      let body = try? JSONSerialization.jsonObject(with: bytes.suffix(from: bytes.index(after: separator))) as? [String: Any] else { return nil }
                let type = (body["exception"] as? [String: Any])?["type"] as? String ?? ""
                let header = (try? JSONSerialization.jsonObject(with: bytes.prefix(upTo: separator))) as? [String: Any]
                let info = body["bundleInfo"] as? [String: Any]
                let reportedTime = date(body["captureTime"]) ?? date(header?["timestamp"])
                return Crash(time: reportedTime ?? time, kind: kinds[type] ?? .unknown,
                    role: file.lastPathComponent.hasPrefix("CangjieXPreview-") ? .inputMethod : .maintenance,
                    version: version(info?["CFBundleShortVersionString"]) ?? version(header?["app_version"]),
                    build: version(info?["CFBundleVersion"]) ?? version(header?["build_version"]),
                    timeSource: reportedTime == nil ? .fileMetadata : .report,
                    pid: (body["pid"] as? Int).flatMap { $0 > 0 ? Int32(exactly: $0) : nil })
            }
        return Array(summaries.sorted { $0.time > $1.time }.prefix(5))
    }

    static func export(home: URL = FileManager.default.homeDirectoryForCurrentUser, includeSystemLog: Bool = true) throws -> URL {
        RuntimeDiagnostics.shared.flush()
        let journal = DiagnosticJournal(home: home)
        let app = InputSourceMaintenance.appURL(home: home)
        let identity = try? UpgradeActivation.installedIdentity(at: app)
        let running = identity == nil ? nil : UpgradeActivation.probeInstalled(at: app)
        let signals = includeSystemLog ? systemSignals() : ([], false)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let executable = app.appendingPathComponent("Contents/MacOS/CangjieXPreview").path
        let pids = ((try? InputSourceMaintenance.processes()) ?? []).filter { $0.uid == getuid() && $0.path == executable }.map(\.pid)
        let report = Report(schema: 1, created: Date(), macOS: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                            installed: identity, running: running, processIDs: pids, state: DiagnosticState.capture(), records: try journal.records(),
                            systemSignals: signals.0, systemLogAvailable: signals.1, crashes: crashes(home: home), manualTypingVerified: false)
        let reports = journal.directory.appendingPathComponent("reports")
        try InputSourceMaintenance.validateParents(of: reports.appendingPathComponent("guard"), home: home)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = reports.appendingPathComponent("diagnostic-\(UUID().uuidString).json")
        let bytes = try JSONEncoder().encode(report)
        try bytes.write(to: target, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let files = try FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])
        let old = files.filter { $0.lastPathComponent.hasPrefix("diagnostic-") && $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in old.dropFirst(3) { try FileManager.default.removeItem(at: file) }
        RuntimeDiagnostics.shared.record(.reportCreated)
        return target
    }

    static func requireSafeRecovery(_ state: DiagnosticState) throws {
        guard state.permitsRecovery else {
            throw InputSourceMaintenance.Failure(message: "請先完成組字、切換到 ABC、離開密碼欄位，並結束「系統設定」，再按修復。診斷記錄可隨時匯出。")
        }
    }

    static func recover(preflight: () throws -> Void, report: () throws -> Void,
                        activate: () throws -> UpgradeActivation.Result, restart: () throws -> Void) throws -> UpgradeActivation.Result {
        try report()
        try preflight()
        RuntimeDiagnostics.shared.record(.recoveryRequested)
        let first: UpgradeActivation.Result?
        do { first = try activate() } catch { first = nil; RuntimeDiagnostics.shared.record(.recoveryFailed) }
        if let first, first.active { RuntimeDiagnostics.shared.record(.recoveryVerified); try report(); return first }
        do {
            try preflight()
            RuntimeDiagnostics.shared.record(.restartRequested)
            try restart()
            let result = try activate()
            RuntimeDiagnostics.shared.record(result.active ? .recoveryVerified : .recoveryFailed)
            try report()
            return result
        } catch {
            RuntimeDiagnostics.shared.record(.recoveryFailed)
            try? report()
            throw error
        }
    }

    static func recoverInstalled() throws -> UpgradeActivation.Result {
        let app = InputSourceMaintenance.appURL(home: FileManager.default.homeDirectoryForCurrentUser)
        let identity = try UpgradeActivation.installedIdentity(at: app)
        var restarted = false
        let check = {
            try requireSafeRecovery(DiagnosticState.capture())
            guard UpgradeActivation.probeInstalled(at: app)?.pendingComposition != true else {
                throw InputSourceMaintenance.Failure(message: "輸入法仍有未完成組字，請先完成文字並切換到 ABC。")
            }
            try InputSourceMaintenance.preflight()
            _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        }
        return try recover(preflight: check, report: { _ = try export() }, activate: {
            if !restarted {
                guard UpgradeActivation.probeInstalled(at: app)?.identity == identity else {
                    return .init(active: false, message: "輸入法程序未回應，將在安全檢查後重啟一次。")
                }
                try UpgradeActivation.refreshRegistration(at: app)
                return .init(active: UpgradeActivation.selectInstalledSource(), message: "系統註冊與選單已刷新；請實際試打確認。")
            }
            return try UpgradeActivation.complete(expected: identity, preflight: check, restart: {}, probe: {
                UpgradeActivation.probeInstalled(at: app)
            }, enable: UpgradeActivation.selectInstalledSource)
        }, restart: {
            try InputSourceMaintenance.execute("repair")
            _ = try InputSourceMaintenance.run("/usr/bin/open", ["-g", "-j", app.path])
            restarted = true
        })
    }
}
