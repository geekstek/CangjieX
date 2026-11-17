import AppKit
import CryptoKit

@main
struct UpgradeActivationTests {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw InputSourceMaintenance.Failure(message: message) }
    }

    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 5 && ["--runtime-fixture", "--old-runtime-fixture"].contains(args[1]) {
            // Read once at launch, just as the real app uses its compiled-in identity.
            let identity = try JSONDecoder().decode(RuntimeBuildIdentity.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            if args[1] == "--old-runtime-fixture" {
                try Data("ready".utf8).write(to: URL(fileURLWithPath: args[4]))
                while true { Thread.sleep(forTimeInterval: 1) }
            }
            let server = RuntimeVersionServer(identity: identity, name: args[3])
            guard server.isListening else { throw InputSourceMaintenance.Failure(message: "Fixture port unavailable") }
            try Data("ready".utf8).write(to: URL(fileURLWithPath: args[4]))
            withExtendedLifetime(server) { RunLoop.current.run() }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cjx-upgrade-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // .fixture is deliberately not a discoverable .app/input method.
        let app = root.appendingPathComponent("Runtime.fixture")
        let bin = app.appendingPathComponent("Contents/MacOS")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("CangjieXPreview")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[0]), to: executable)
        let manifest = resources.appendingPathComponent("RuntimeBuild.json")
        let old = RuntimeBuildIdentity(version: "2.0.2", buildID: UUID().uuidString)
        let new = RuntimeBuildIdentity(version: "2.0.2", buildID: UUID().uuidString)
        let plist = ["CFBundleIdentifier": InputSourceMaintenance.identifier, "CFBundleDisplayName": "倉頡星", "CFBundleShortVersionString": new.version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let service = "io.github.geekstek.cangjiex.runtime-test.\(UUID().uuidString)"
        let ready = root.appendingPathComponent("ready")
        var child: Process?
        func stop() {
            if let process = child, process.isRunning { process.terminate(); process.waitUntilExit() }
            child = nil
        }
        defer { stop() }
        func start(legacy: Bool = false) throws {
            try? FileManager.default.removeItem(at: ready)
            let process = Process()
            process.executableURL = executable
            process.arguments = [legacy ? "--old-runtime-fixture" : "--runtime-fixture", manifest.path, service, ready.path]
            try process.run()
            child = process
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: ready.path) { return }
                Thread.sleep(forTimeInterval: 0.02)
            }
            throw InputSourceMaintenance.Failure(message: "Fixture process did not start")
        }
        try JSONEncoder().encode(old).write(to: manifest)
        try start()
        let oldInode = try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? NSNumber
        let replacement = bin.appendingPathComponent("replacement")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[0]), to: replacement)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.moveItem(at: replacement, to: executable)
        try check(try FileManager.default.attributesOfItem(atPath: executable.path)[.systemFileNumber] as? NSNumber != oldInode,
                  "Upgrade fixture must replace the on-disk executable while old process remains alive")
        try JSONEncoder().encode(new).write(to: manifest)
        try check(try UpgradeActivation.installedIdentity(at: app) == new, "New disk identity missing")
        try check(UpgradeActivation.probeInstalled(at: app, serviceName: service)?.identity == old, "Live process must keep its old identity after disk replacement")
        try check(UpgradeActivation.probeInstalled(at: root.appendingPathComponent("wrong"), serviceName: service) == nil, "Probe accepted a process at another executable path")
        var events: [String] = []
        let result = try UpgradeActivation.complete(expected: new, preflight: { events.append("preflight") }, restart: {
            events.append("restart"); stop(); try start()
        }, probe: { UpgradeActivation.probeInstalled(at: app, serviceName: service) }, enable: { events.append("enable"); return true })
        try check(result.active && events == ["preflight", "restart", "enable"], "Old live process was accepted as the new build")
        events = []
        let already = try UpgradeActivation.complete(expected: new, preflight: {}, restart: { events.append("restart") },
            probe: { UpgradeActivation.probeInstalled(at: app, serviceName: service) }, enable: { true })
        try check(already.active && events.isEmpty, "Healthy new process restarted unnecessarily")
        stop()
        try start(legacy: true)
        events = []
        let fromLegacy = try UpgradeActivation.complete(expected: new, preflight: {}, restart: {
            events.append("restart"); stop(); try start()
        }, probe: { UpgradeActivation.probeInstalled(at: app, serviceName: service) }, enable: { true })
        try check(fromLegacy.active && events == ["restart"], "An old version without a runtime endpoint did not upgrade safely")
        events = []
        let timeout = try UpgradeActivation.complete(expected: new, preflight: {}, restart: {}, probe: { nil }, enable: { true }, attempts: 1)
        try check(!timeout.active && timeout.message.contains("不算完成"), "Missing runtime verification was reported as success")
        let disabled = try UpgradeActivation.complete(expected: new, preflight: {}, restart: { events.append("restart") },
            probe: { UpgradeActivation.probeInstalled(at: app, serviceName: service) }, enable: { false })
        try check(!disabled.active && events.isEmpty, "Unavailable input source was reported active or restarted unnecessarily")
        var wroteFiles = false
        var stopped = false
        do {
            _ = try InstallUI.install(expected: new, preflight: { throw InputSourceMaintenance.Failure(message: "ABC required") },
                stopCurrent: { stopped = true }, writePackage: { wroteFiles = true },
                inspect: { new }, activate: { result })
            throw InputSourceMaintenance.Failure(message: "Active source did not block installation")
        } catch { try check(!wroteFiles && !stopped, "Preflight refusal wrote app files or stopped active input method") }
        var steps: [String] = []
        let pending = try InstallUI.install(expected: new, preflight: { steps.append("check") }, stopCurrent: { steps.append("stop") }, writePackage: { wroteFiles = true; steps.append("write") },
            inspect: { steps.append("inspect"); return new }, activate: { steps.append("activate"); return timeout })
        try check(wroteFiles && !pending.active, "File installation alone was reported as completed activation")
        try check(steps == ["check", "stop", "check", "write", "inspect", "activate"], "Upgrade steps ran in an unsafe order")
        let ui = InstallUI.completion(pending)
        try check(ui.messageText.contains("尚未完成") && ui.informativeText.contains("重新登入"), "Pending activation UI falsely claims completion")
        ui.window.close()
        let introduction = InstallUI.introduction(version: new.version)
        DispatchQueue.main.async { introduction.buttons[1].performClick(nil) }
        try check(introduction.runModal() == .alertSecondButtonReturn, "Installer introduction did not cancel")
        introduction.window.close()
        let package = root.appendingPathComponent("payload.pkg")
        try Data("synthetic payload".utf8).write(to: package)
        let metadata = InstallUI.PayloadMetadata(identity: new, sha256: SHA256.hash(data: try Data(contentsOf: package)).map { String(format: "%02x", $0) }.joined())
        try InstallUI.verifyPayload(package, metadata: metadata)
        try Data("tampered".utf8).write(to: package)
        do {
            try InstallUI.verifyPayload(package, metadata: metadata)
            throw InputSourceMaintenance.Failure(message: "Tampered package accepted")
        } catch { try check(error.localizedDescription.contains("校驗失敗"), "Payload verification did not reject modification") }
        print("PASS: real old process + new on-disk identity, cross-process nonce/PID/path verification, safe restart, same-version build mismatch, timeout/enable fallback, pre-install guard and payload digest. No daily-use input source was changed.")
    }
}
