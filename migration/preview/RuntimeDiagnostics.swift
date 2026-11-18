import AppKit
import Carbon
import Darwin
import os

// No free-form messages, key events, text, candidates or learning data enter this schema.
enum DiagnosticEvent: String, Codable {
    case startup, shutdown, heartbeat, sourceChanged, sourcesChanged, wake, sleep, sessionActive, sessionInactive
    case controllerActivated, controllerDeactivated, controllerClosed, clientUnavailable
    case engineCreationFailed, engineEventFailed, compositionFailed, settingsFailed, slowInput, mainLoopUnresponsive
    case reportCreated, recoveryRequested, recoveryDeferred, registryRefreshed, recoveryVerified, recoveryFailed
    case restartRequested, registrationFailed, selectionFailed, automaticRefreshRequested
    case serverReady, serverStartFailed, runtimeProbeUnavailable
    case systemConnectionSignals, systemLogUnavailable
    case signatureCheckFailed, registryCommandFailed, processCommandFailed, launchCommandFailed, packageCommandFailed, maintenanceCommandFailed
}

enum DiagnosticCommand: String, Codable {
    case status, check, activate, diagnose, recover, repair, uninstall, install, invalid
    case verifyUninstall = "verify-uninstall"
    case diagnosticsDialog = "diagnostics-dialog"
    case uninstallDialog = "uninstall-dialog"
}

struct DiagnosticState: Codable, Equatable {
    enum Selection: String, Codable { case own, abc, other, unknown }
    let selection: Selection
    let sourceCount: Int
    let enabled: Bool
    let selectCapable: Bool
    let secureInput: Bool
    let settingsOpen: Bool
    let pendingComposition: Bool

    static func capture() -> Self {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let id = InputSourceMaintenance.sourceProperty(current, kTISPropertyInputSourceID) as? String ?? ""
        let sources = InputSourceMaintenance.sources(InputSourceMaintenance.identifier)
        func flag(_ key: CFString) -> Bool {
            sources.contains { (InputSourceMaintenance.sourceProperty($0, key) as? NSNumber)?.boolValue == true }
        }
        return Self(selection: InputSourceMaintenance.ownedIDs.contains(id) ? .own : id == "com.apple.keylayout.ABC" ? .abc : id.isEmpty ? .unknown : .other,
                    sourceCount: sources.count, enabled: flag(kTISPropertyInputSourceIsEnabled),
                    selectCapable: flag(kTISPropertyInputSourceIsSelectCapable), secureInput: IsSecureEventInputEnabled(),
                    settingsOpen: NSWorkspace.shared.runningApplications.contains { ["com.apple.systempreferences", "com.apple.systemsettings"].contains($0.bundleIdentifier ?? "") },
                    pendingComposition: DiagnosticCompositionActivity.shared.hasPending)
    }

    var permitsRecovery: Bool { selection == .abc && !secureInput && !settingsOpen && !pendingComposition }
}

final class DiagnosticCompositionActivity {
    static let shared = DiagnosticCompositionActivity()
    private let lock = NSLock()
    private var pending: Set<ObjectIdentifier> = []
    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return !pending.isEmpty }
    func update(_ controller: AnyObject, pending: Bool) {
        lock.lock(); defer { lock.unlock() }
        if pending { self.pending.insert(ObjectIdentifier(controller)) } else { self.pending.remove(ObjectIdentifier(controller)) }
    }
}

struct DiagnosticRecord: Codable {
    enum Role: String, Codable { case inputMethod, maintenance }
    let schema: Int
    let time: Date
    let run: UUID
    let pid: Int32
    let role: Role
    let identity: RuntimeBuildIdentity?
    let event: DiagnosticEvent
    let state: DiagnosticState?
    let status: Int32?
    let elapsedMilliseconds: Int?
    var systemSignals: [DiagnosticReport.SystemSignal]? = nil
    var command: DiagnosticCommand? = nil
}

final class DiagnosticJournal {
    static let segmentLimit = 256 * 1024
    static let segmentCount = 4
    let home: URL
    let directory: URL
    private let limit: Int

    init(home: URL, segmentLimit: Int = DiagnosticJournal.segmentLimit) {
        self.home = home
        limit = segmentLimit
        directory = home.appendingPathComponent("Library/Logs/\(InputSourceMaintenance.identifier)")
    }

    func prepare() throws {
        try InputSourceMaintenance.validateParents(of: directory.appendingPathComponent("guard"), home: home)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let a = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard a[.type] as? FileAttributeType == .typeDirectory, (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw InputSourceMaintenance.Failure(message: "診斷目錄不安全，未寫入記錄。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try prepare()
        let fd = open(directory.appendingPathComponent("journal.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InputSourceMaintenance.Failure(message: "無法開啟診斷記錄鎖。") }
        defer { close(fd) }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1, flock(fd, LOCK_EX) == 0 else {
            throw InputSourceMaintenance.Failure(message: "診斷記錄鎖不安全。")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    private func segment(_ index: Int) -> URL {
        directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl")
    }

    private func validateFile(_ url: URL) throws {
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path) {
            guard a[.type] as? FileAttributeType == .typeRegular,
                  (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(), (a[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw InputSourceMaintenance.Failure(message: "診斷檔案不安全，停止存取。")
            }
        }
    }

    func append(_ record: DiagnosticRecord) throws {
        var bytes = try JSONEncoder().encode(record)
        bytes.append(10)
        guard bytes.count < 8192 else { return }
        try locked {
            for i in 0..<Self.segmentCount { try validateFile(segment(i)) }
            let size = (try? FileManager.default.attributesOfItem(atPath: segment(0).path)[.size] as? NSNumber)?.intValue ?? 0
            if size + bytes.count + 1 > limit {
                let last = segment(Self.segmentCount - 1)
                if FileManager.default.fileExists(atPath: last.path) { try FileManager.default.removeItem(at: last) }
                for i in stride(from: Self.segmentCount - 2, through: 0, by: -1) where FileManager.default.fileExists(atPath: segment(i).path) {
                    try FileManager.default.moveItem(at: segment(i), to: segment(i + 1))
                }
            }
            let fd = open(segment(0).path, O_CREAT | O_RDWR | O_APPEND | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw InputSourceMaintenance.Failure(message: "無法寫入診斷記錄。") }
            defer { close(fd) }
            var current = stat()
            guard fstat(fd, &current) == 0, current.st_mode & S_IFMT == S_IFREG,
                  current.st_uid == getuid(), current.st_nlink == 1 else {
                throw InputSourceMaintenance.Failure(message: "診斷檔案不安全，停止寫入。")
            }
            _ = fchmod(fd, 0o600)
            if current.st_size > 0 {
                var last: UInt8 = 0
                if pread(fd, &last, 1, current.st_size - 1) == 1 && last != 10 {
                    var newline: UInt8 = 10
                    guard Darwin.write(fd, &newline, 1) == 1 else { throw InputSourceMaintenance.Failure(message: "無法修復未完成的診斷記錄。") }
                }
            }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    guard count > 0 else { throw InputSourceMaintenance.Failure(message: "診斷記錄寫入失敗。") }
                    offset += count
                }
            }
        }
    }

    func records() throws -> [DiagnosticRecord] {
        try locked {
            var records: [DiagnosticRecord] = []
            for i in (0..<Self.segmentCount).reversed() {
                let file = segment(i)
                try validateFile(file)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue else { continue }
                guard size <= limit else { continue }
                let data = try Data(contentsOf: file)
                records += data.split(separator: 10).compactMap { try? JSONDecoder().decode(DiagnosticRecord.self, from: Data($0)) }
            }
            return records
        }
    }
}

final class RuntimeDiagnostics {
    static let shared = RuntimeDiagnostics()
    private let queue = DispatchQueue(label: "io.github.geekstek.CangjieX.diagnostics", qos: .utility)
    private let logger = Logger(subsystem: InputSourceMaintenance.identifier, category: "Diagnostics")
    private var journal: DiagnosticJournal?
    private var role = DiagnosticRecord.Role.inputMethod
    private var identity: RuntimeBuildIdentity?
    private let run = UUID()
    private var lastError: [DiagnosticEvent: TimeInterval] = [:]

    // Tests leave the singleton unconfigured; fixture journals always use temporary homes.
    func configure(role: DiagnosticRecord.Role, identity: RuntimeBuildIdentity?, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        queue.sync { self.journal = DiagnosticJournal(home: home); self.role = role; self.identity = identity }
    }

    func disable() { queue.sync { journal = nil } }
    func flush() { queue.sync {} }

    func record(_ event: DiagnosticEvent, state: DiagnosticState? = nil, status: Int32? = nil, milliseconds: Int? = nil,
                signals: [DiagnosticReport.SystemSignal]? = nil, command: DiagnosticCommand? = nil) {
        queue.async { [self] in
            guard let journal else { return }
            if [.engineEventFailed, .clientUnavailable, .compositionFailed, .slowInput, .mainLoopUnresponsive].contains(event) {
                let now = ProcessInfo.processInfo.systemUptime
                if let last = lastError[event], now - last < 10 { return }
                lastError[event] = now
            }
            do {
                var record = DiagnosticRecord(schema: 1, time: Date(), run: run, pid: getpid(), role: role, identity: identity,
                                              event: event, state: state, status: status, elapsedMilliseconds: milliseconds)
                record.systemSignals = signals
                record.command = command
                try journal.append(record)
                logger.info("Diagnostic event: \(event.rawValue, privacy: .public)")
            } catch { logger.error("Diagnostic journal unavailable") }
        }
    }
}

struct AutomaticRefreshPolicy {
    var requestedAt: TimeInterval?
    var lastAttempt: TimeInterval?

    mutating func request(now: TimeInterval) { requestedAt = now }
    mutating func shouldAttempt(now: TimeInterval, state: DiagnosticState) -> Bool {
        guard let requestedAt else { return false }
        guard now - requestedAt < 900 else { self.requestedAt = nil; return false }
        guard state.permitsRecovery, state.enabled, state.sourceCount == 1,
              lastAttempt.map({ now - $0 >= 600 }) ?? true else { return false }
        self.requestedAt = nil
        lastAttempt = now
        return true
    }
}

final class InputMethodDiagnosticsMonitor {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributed: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var policy = AutomaticRefreshPolicy()
    private let installed: Bool
    private var ticks = 0

    init() {
        installed = InputSourceMaintenance.isInstalledLocation(Bundle.main.bundleURL)
    }

    func start() {
        guard installed else { return }
        capture(.heartbeat)
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event) in [(NSWorkspace.didWakeNotification, DiagnosticEvent.wake), (NSWorkspace.willSleepNotification, .sleep),
                              (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive), (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive)] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                if event == .wake || event == .sessionActive { self?.policy.request(now: ProcessInfo.processInfo.systemUptime) }
                self?.capture(event)
            }))
        }
        for (name, event) in [(kTISNotifySelectedKeyboardInputSourceChanged, DiagnosticEvent.sourceChanged),
                              (kTISNotifyEnabledKeyboardInputSourcesChanged, .sourcesChanged)] {
            guard let name else { continue }
            distributed.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name as String), object: nil, queue: .main) { [weak self] _ in self?.capture(event) })
        }
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            RuntimeDiagnostics.shared.record(.shutdown)
            RuntimeDiagnostics.shared.flush()
        }))
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let acknowledged = DispatchGroup()
            acknowledged.enter()
            DispatchQueue.main.async { self.capture(.heartbeat); acknowledged.leave() }
            if acknowledged.wait(timeout: .now() + 5) == .timedOut { RuntimeDiagnostics.shared.record(.mainLoopUnresponsive, milliseconds: 5000) }
            self.ticks += 1
            if self.ticks % 5 == 0 {
                let (signals, available) = DiagnosticReport.systemSignals()
                if !available { RuntimeDiagnostics.shared.record(.systemLogUnavailable) }
                for start in stride(from: 0, to: signals.count, by: 20) {
                    RuntimeDiagnostics.shared.record(.systemConnectionSignals, signals: Array(signals.dropFirst(start).prefix(20)))
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func capture(_ event: DiagnosticEvent) {
        let state = DiagnosticState.capture()
        RuntimeDiagnostics.shared.record(event, state: state)
        guard policy.shouldAttempt(now: ProcessInfo.processInfo.systemUptime, state: state) else { return }
        // This only refreshes registration/menu metadata; it never selects, enables or restarts an input method.
        RuntimeDiagnostics.shared.record(.automaticRefreshRequested, state: state)
        do {
            try InputSourceMaintenance.preflight()
            guard DiagnosticState.capture().permitsRecovery else { RuntimeDiagnostics.shared.record(.recoveryDeferred); return }
            let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
            guard status == noErr else { RuntimeDiagnostics.shared.record(.registrationFailed, status: status); return }
            try InputSourceMaintenance.refreshCatalog(clearShared: false)
            RuntimeDiagnostics.shared.record(.registryRefreshed, state: DiagnosticState.capture())
        } catch { RuntimeDiagnostics.shared.record(.recoveryDeferred, state: DiagnosticState.capture()) }
    }

    deinit {
        timer?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        for observer in distributed { DistributedNotificationCenter.default().removeObserver(observer) }
    }
}
