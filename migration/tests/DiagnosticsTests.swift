import AppKit

enum DiagnosticsTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw InputSourceMaintenance.Failure(message: message) }
    }
    static func refuses(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw InputSourceMaintenance.Failure(message: "Unsafe diagnostics operation was accepted")
    }
    static func record(_ event: DiagnosticEvent = .heartbeat, status: Int32? = nil) -> DiagnosticRecord {
        DiagnosticRecord(schema: 1, time: Date(), run: UUID(), pid: getpid(), role: .inputMethod,
                         identity: RuntimeBuildIdentity(version: "2.0.4", buildID: UUID().uuidString),
                         event: event, state: nil, status: status, elapsedMilliseconds: nil)
    }
    static func state(selection: DiagnosticState.Selection = .abc, enabled: Bool = true, count: Int = 1,
                      secure: Bool = false, settings: Bool = false, pending: Bool = false) -> DiagnosticState {
        DiagnosticState(selection: selection, sourceCount: count, enabled: enabled, selectCapable: true,
                        secureInput: secure, settingsOpen: settings, pendingComposition: pending)
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cjx-diagnostics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { RuntimeDiagnostics.shared.disable(); try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let installedPath = InputSourceMaintenance.appURL(home: home).path
        for directory in [false, true] {
            try check(InputSourceMaintenance.isInstalledLocation(URL(fileURLWithPath: installedPath, isDirectory: directory), home: home),
                      "Directory URL representation disabled diagnostics at the installed location")
        }
        try check(!InputSourceMaintenance.isInstalledLocation(root.appendingPathComponent("other.app"), home: home), "A development copy was treated as the daily installation")
        let journal = DiagnosticJournal(home: home)
        try journal.append(record(.startup))
        let file = journal.directory.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"unfinished\":".utf8)); try handle.close()
        try journal.append(record(.engineEventFailed, status: -2))
        try check(try journal.records().count == 2, "A partial crash-time record swallowed the next valid record")
        for (path, mode) in [(journal.directory, 0o700), (file, 0o600)] {
            let actual = (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue
            try check(actual & 0o777 == mode, "Diagnostic permissions are too broad")
        }

        let rotated = DiagnosticJournal(home: root.appendingPathComponent("rotation"), segmentLimit: 4096)
        for i in 0..<100 { try rotated.append(record(status: Int32(i))) }
        let segments = try FileManager.default.contentsOfDirectory(at: rotated.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
        try check(segments.count == 4, "Diagnostic rotation did not retain exactly four bounded segments")
        for segment in segments {
            try check((try FileManager.default.attributesOfItem(atPath: segment.path)[.size] as! NSNumber).intValue <= 4096, "Diagnostic segment exceeded limit")
        }
        try check(try rotated.records().last?.status == 99 && rotated.records().count < 100, "Rotation lost the newest record or kept unbounded history")

        let concurrentHome = root.appendingPathComponent("concurrent")
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            try! DiagnosticJournal(home: concurrentHome).append(record(status: Int32(i)))
        }
        try check(try DiagnosticJournal(home: concurrentHome).records().count == 20, "Concurrent diagnostic writers lost or corrupted records")

        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let marker = external.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: marker)
        let unsafe = DiagnosticJournal(home: root.appendingPathComponent("unsafe"))
        try FileManager.default.createDirectory(at: unsafe.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: unsafe.directory, withDestinationURL: external)
        try refuses { try unsafe.append(record()) }
        let linked = DiagnosticJournal(home: root.appendingPathComponent("linked"))
        try linked.prepare()
        try FileManager.default.linkItem(at: marker, to: linked.directory.appendingPathComponent("events.jsonl"))
        try refuses { try linked.append(record()) }
        try check(try String(contentsOf: marker, encoding: .utf8) == "keep", "Diagnostic file safeguards changed an unrelated file")

        let secret = "SYNTHETIC-TYPED-TEXT-CANDIDATES-LEARNING-DO-NOT-EXPORT"
        let raw: [[String: Any]] = [
            ["timestamp": "2026-11-18 13:00:00.000+0800", "eventMessage": "NO Endpoint \(secret)", "processImagePath": "/usr/libexec/imklaunchagent"],
            ["timestamp": "2026-11-18 13:00:01.000+0800", "eventMessage": "Endpoint Invalid \(secret)", "processImagePath": "/private/\(secret)/CangjieXPreview"],
            ["timestamp": secret, "eventMessage": "NO Endpoint"],
        ]
        let signals = DiagnosticReport.signals(from: try JSONSerialization.data(withJSONObject: raw))
        try check(signals.count == 2 && !signals[0].ownProcess && signals[1].ownProcess, "System endpoint metadata lost attribution or accepted arbitrary text")
        try check(!String(decoding: try JSONEncoder().encode(signals), as: UTF8.self).contains(secret), "Raw system log text leaked into normalized signals")
        var extra = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record())) as! [String: Any]
        extra["typedText"] = secret
        let append = try FileHandle(forWritingTo: file)
        try append.seekToEnd(); try append.write(contentsOf: JSONSerialization.data(withJSONObject: extra) + Data([10])); try append.close()
        let crashRoot = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        try FileManager.default.createDirectory(at: crashRoot, withIntermediateDirectories: true)
        let crash = crashRoot.appendingPathComponent("CangjieXPreview-fixture.ips")
        let body: [String: Any] = ["exception": ["type": "EXC_CRASH"], "asi": secret]
        try (Data("{}\n".utf8) + JSONSerialization.data(withJSONObject: body)).write(to: crash)
        var report: URL!
        for _ in 0..<4 { report = try DiagnosticReport.export(home: home, includeSystemLog: false) }
        let exported = try Data(contentsOf: report)
        try check(!String(decoding: exported, as: UTF8.self).contains(secret), "Diagnostic export included input, arbitrary fields or raw crash contents")
        let decoded = try JSONDecoder().decode(DiagnosticReport.Report.self, from: exported)
        try check(decoded.crashes.count == 1 && decoded.crashes[0].kind == .crash && !decoded.manualTypingVerified, "Crash summary or unverified manual typing claim is wrong")
        try check(decoded.crashes[0].role == .inputMethod && decoded.crashes[0].version == nil
                  && decoded.crashes[0].timeSource == .fileMetadata, "Unknown crash metadata was guessed")
        let reports = try FileManager.default.contentsOfDirectory(at: report.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        try check(reports.count == 3, "Report retention is not bounded")

        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: crash.path)
        for index in 0..<6 {
            let name = index.isMultiple(of: 2) ? "CangjieXPreview-" : "CangjieXMaintenance-"
            let target = crashRoot.appendingPathComponent("\(name)fixture-\(index).ips")
            let header: [String: Any] = ["app_version": index == 5 ? secret : "0.1.0", "build_version": "2"]
            let body: [String: Any] = ["captureTime": "2026-11-18 12:00:0\(index).1234 +0800", "pid": index + 100,
                "exception": ["type": "EXC_BAD_ACCESS"], "asi": secret,
                "bundleInfo": ["CFBundleShortVersionString": index == 5 ? secret : "2.0.4", "CFBundleVersion": index == 5 ? secret : "7"]]
            try (JSONSerialization.data(withJSONObject: header) + Data([10]) + JSONSerialization.data(withJSONObject: body)).write(to: target)
            // Neither the process-name prefix nor a copied file's modification time is crash chronology.
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: index == 0 ? 2_000_000_000 : 1_000_000_000)], ofItemAtPath: target.path)
        }
        let crashes = DiagnosticReport.crashes(home: home)
        try check(crashes.count == 5 && crashes.map(\.time) == crashes.map(\.time).sorted(by: >)
                  && crashes[0].role == .maintenance && crashes[1].role == .inputMethod
                  && crashes.allSatisfy { $0.timeSource == .report } && crashes[0].pid == 105,
                  "Crash retention did not follow report timestamps across both roles")
        try check(crashes[0].version == nil && crashes[0].build == "2" && crashes[1].version == "2.0.4"
                  && crashes[1].build == "7", "Crash versions were lost, guessed or copied without validation")
        try check(!String(decoding: try JSONEncoder().encode(crashes), as: UTF8.self).contains(secret), "Raw crash metadata leaked")
        let oldCrash = try JSONDecoder().decode(DiagnosticReport.Crash.self, from: Data("{\"time\":1,\"kind\":\"badAccess\"}".utf8))
        try check(oldCrash.role == nil && oldCrash.version == nil && oldCrash.timeSource == nil, "Historical crash summaries stopped decoding")

        let commandHome = root.appendingPathComponent("command-context")
        RuntimeDiagnostics.shared.configure(role: .maintenance, identity: nil, home: commandHome)
        RuntimeDiagnostics.shared.record(.maintenanceCommandFailed, state: state(selection: .own), command: .check)
        RuntimeDiagnostics.shared.record(.maintenanceCommandFailed, command: DiagnosticCommand(rawValue: secret) ?? .invalid)
        RuntimeDiagnostics.shared.flush()
        let commands = try DiagnosticJournal(home: commandHome).records()
        try check(commands.count == 2 && commands[0].event == .maintenanceCommandFailed
                  && commands[0].command == .check && commands[0].state?.selection == .own
                  && commands[1].command == .invalid, "Maintenance failure lost its safe command/state classification")
        try check(!String(decoding: try JSONEncoder().encode(commands), as: UTF8.self).contains(secret), "Command arguments leaked into diagnostics")
        try check(try JSONDecoder().decode(DiagnosticRecord.self, from: JSONEncoder().encode(record())).command == nil,
                  "Existing diagnostic records no longer decode")

        let throttledHome = root.appendingPathComponent("throttle")
        RuntimeDiagnostics.shared.configure(role: .maintenance, identity: nil, home: throttledHome)
        for _ in 0..<20 { RuntimeDiagnostics.shared.record(.engineEventFailed, status: -2) }
        RuntimeDiagnostics.shared.flush()
        try check(try DiagnosticJournal(home: throttledHome).records().count == 1, "Repeated errors flooded the journal")
        RuntimeDiagnostics.shared.disable()

        for blocked in [state(selection: .own), state(selection: .other), state(secure: true), state(settings: true), state(pending: true)] {
            try refuses { try DiagnosticReport.requireSafeRecovery(blocked) }
            var policy = AutomaticRefreshPolicy(); policy.request(now: 10)
            try check(!policy.shouldAttempt(now: 11, state: blocked), "Automatic refresh ignored a safety guard")
        }
        var policy = AutomaticRefreshPolicy(); policy.request(now: 10)
        try check(!policy.shouldAttempt(now: 11, state: state(enabled: false)), "Automatic refresh would restore a deliberately disabled source")
        try check(!policy.shouldAttempt(now: 12, state: state(count: 2)), "Ambiguous sources were automatically modified")
        try check(policy.shouldAttempt(now: 13, state: state()), "Safe refresh was never attempted")
        policy.request(now: 14)
        try check(!policy.shouldAttempt(now: 15, state: state()), "Automatic refresh lacked a cooldown")
        try check(policy.shouldAttempt(now: 614, state: state()), "Cooldown did not expire")
        policy.request(now: 700)
        try check(!policy.shouldAttempt(now: 1601, state: state()), "Expired refresh ran long after the trigger")

        var events: [String] = [], attempts = 0
        let fixed = try DiagnosticReport.recover(preflight: { events.append("check") }, report: { events.append("report") }, activate: {
            attempts += 1; events.append("activate"); return .init(active: attempts == 2, message: "fixture")
        }, restart: { events.append("restart") })
        try check(fixed.active && events == ["report", "check", "activate", "check", "restart", "activate", "report"], "Recovery did not capture before fixing or retry exactly once")
        events = []
        _ = try DiagnosticReport.recover(preflight: {}, report: {}, activate: { .init(active: true, message: "fixture") }, restart: { events.append("restart") })
        try check(events.isEmpty, "Healthy registry refresh unnecessarily restarted the input method")
        events = []
        try refuses {
            _ = try DiagnosticReport.recover(preflight: { throw InputSourceMaintenance.Failure(message: "guard") }, report: { events.append("report") },
                activate: { events.append("activate"); return .init(active: true, message: "fixture") }, restart: { events.append("restart") })
        }
        try check(events == ["report"], "Blocked recovery changed the input method")
        try check(InputSourceMaintenance.dataPaths(home: home).contains { $0.path == journal.directory.path }, "Complete uninstall would leave diagnostic logs behind")
        try InputSourceMaintenance.purgeUserData(home: home)
        try check(!FileManager.default.fileExists(atPath: journal.directory.path), "Complete data removal left diagnostics behind")
        print("PASS: bounded/private crash-safe diagnostics, concurrent writes, privacy filtering, export/crash summaries, retention, recovery guards, cooldown and one-retry repair; fixture data only.")
    }
}
