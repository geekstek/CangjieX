import Foundation
import Carbon

enum UpgradeActivation {
    struct Result {
        let active: Bool
        let message: String
    }

    static func installedIdentity(at app: URL) throws -> RuntimeBuildIdentity {
        try InputSourceMaintenance.validateApp(app)
        let identity = try JSONDecoder().decode(RuntimeBuildIdentity.self, from: Data(contentsOf: app.appendingPathComponent("Contents/Resources/RuntimeBuild.json")))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil) as? [String: Any]
        guard identity.version == plist?["CFBundleShortVersionString"] as? String, UUID(uuidString: identity.buildID) != nil else {
            throw InputSourceMaintenance.Failure(message: "已安裝程式的版本識別不一致，不能確認升級完成。")
        }
        return identity
    }

    // A file version is insufficient: only the running process can return this build ID.
    static func complete(expected: RuntimeBuildIdentity, preflight: () throws -> Void,
                         restart: () throws -> Void, probe: () -> RuntimeVersionReply?,
                         enable: () -> Bool, attempts: Int = 30) throws -> Result {
        try preflight()
        if let reply = probe(), reply.identity == expected {
            let enabled = enable()
            return Result(active: enabled, message: enabled ? "已啟用並驗證倉頡星 \(expected.version)。" : "新版已啟動，但輸入來源尚未啟用；請重新登入完成啟用。")
        }
        try restart()
        for _ in 0..<attempts {
            if let reply = probe(), reply.identity == expected {
                guard enable() else {
                    return Result(active: false, message: "新版程序已啟動，但系統尚未允許啟用輸入來源。請保存工作後登出並重新登入，升級才算完成。")
                }
                return Result(active: true, message: "已啟用並驗證倉頡星 \(expected.version)。")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return Result(active: false, message: "檔案已安裝，但尚未確認新版程序正在執行。請保存工作後登出並重新登入；目前不算完成啟用。")
    }

    static func probeInstalled(at app: URL, serviceName: String = RuntimeVersionServer.serviceName) -> RuntimeVersionReply? {
        let executable = app.appendingPathComponent("Contents/MacOS/CangjieXPreview").path
        guard let reply = RuntimeVersionServer.probe(name: serviceName),
              let processes = try? InputSourceMaintenance.processes(),
              processes.contains(where: { $0.pid == reply.pid && $0.uid == getuid() && $0.path == executable }) else { return nil }
        return reply
    }

    static func activateInstalled() throws -> Result {
        let app = InputSourceMaintenance.appURL(home: FileManager.default.homeDirectoryForCurrentUser)
        let identity = try installedIdentity(at: app)
        _ = try InputSourceMaintenance.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        if probeInstalled(at: app)?.identity == identity {
            // Even a healthy process can coexist with old menu/panel metadata.
            try InputSourceMaintenance.preflight()
            _ = try InputSourceMaintenance.run(InputSourceMaintenance.registrar, ["-f", app.path])
            guard TISRegisterInputSource(app as CFURL) == noErr else {
                throw InputSourceMaintenance.Failure(message: "新版程序已執行，但註冊尚未更新；請重新登入完成啟用。")
            }
            try InputSourceMaintenance.refreshCatalog(clearShared: false)
        }
        return try complete(expected: identity, preflight: InputSourceMaintenance.preflight, restart: {
            try InputSourceMaintenance.preflight()
            try InputSourceMaintenance.execute("repair")
            _ = try InputSourceMaintenance.run("/usr/bin/open", ["-g", "-j", app.path])
        }, probe: {
            probeInstalled(at: app)
        }, enable: {
            guard let source = InputSourceMaintenance.sources(InputSourceMaintenance.identifier).first else { return false }
            guard TISEnableInputSource(source) == noErr else { return false }
            for _ in 0..<5 {
                if TISSelectInputSource(source) == noErr {
                    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
                    if InputSourceMaintenance.sourceProperty(current, kTISPropertyInputSourceID) as? String == InputSourceMaintenance.identifier { return true }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        })
    }
}
