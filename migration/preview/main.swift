import AppKit
import Carbon
import InputMethodKit

let identifier = "io.github.geekstek.inputmethod.CangjieXPreview"
guard Bundle.main.bundleIdentifier == identifier else {
    fatalError("Preview must run from its own application bundle")
}
if CommandLine.arguments.contains("--register-preview") {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    guard status == noErr else {
        FileHandle.standardError.write(Data("Preview registration failed: \(status)\n".utf8))
        exit(1)
    }
    print("Registered 倉頡星. Add it in Keyboard > Text Input to try it.")
    exit(0)
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let installed = InputSourceMaintenance.isInstalledLocation(Bundle.main.bundleURL)
if installed {
    RuntimeDiagnostics.shared.configure(role: .inputMethod, identity: RuntimeBuildIdentity(version: CompiledRuntimeBuild.version, buildID: CompiledRuntimeBuild.buildID))
    RuntimeDiagnostics.shared.record(.startup, state: DiagnosticState.capture())
}
guard let server = IMKServer(name: "io.github.geekstek.inputmethod.CangjieXPreview_Connection", bundleIdentifier: identifier) else {
    RuntimeDiagnostics.shared.record(.serverStartFailed)
    RuntimeDiagnostics.shared.flush()
    fatalError("Could not create the Preview input method server")
}
RuntimeDiagnostics.shared.record(.serverReady)
let runtime = RuntimeVersionServer(identity: RuntimeBuildIdentity(version: CompiledRuntimeBuild.version, buildID: CompiledRuntimeBuild.buildID))
if !runtime.isListening { RuntimeDiagnostics.shared.record(.runtimeProbeUnavailable) }
let diagnostics = InputMethodDiagnosticsMonitor()
diagnostics.start()
withExtendedLifetime((server, runtime, diagnostics)) { application.run() }
