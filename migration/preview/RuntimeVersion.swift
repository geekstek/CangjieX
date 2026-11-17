import Foundation
import CoreFoundation

struct RuntimeBuildIdentity: Codable, Equatable {
    let version: String
    let buildID: String
}

struct RuntimeVersionReply: Codable {
    let nonce: String
    let identity: RuntimeBuildIdentity
    let pid: Int32
}

final class RuntimeVersionServer {
    static var serviceName: String { "io.github.geekstek.CangjieX.runtime.\(getuid())" }
    let identity: RuntimeBuildIdentity
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?
    var isListening: Bool { port.map { CFMessagePortIsValid($0) } ?? false }

    init(identity: RuntimeBuildIdentity, name: String = RuntimeVersionServer.serviceName) {
        self.identity = identity
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        port = CFMessagePortCreateLocal(nil, name as CFString, { _, message, data, info in
            guard message == 1, let data, CFDataGetLength(data) <= 128, let info,
                  let nonce = String(data: data as Data, encoding: .utf8), UUID(uuidString: nonce) != nil else { return nil }
            let server = Unmanaged<RuntimeVersionServer>.fromOpaque(info).takeUnretainedValue()
            let reply = RuntimeVersionReply(nonce: nonce, identity: server.identity, pid: getpid())
            guard let bytes = try? JSONEncoder().encode(reply) else { return nil }
            return Unmanaged.passRetained(bytes as CFData)
        }, &context, nil)
        if let port {
            source = CFMessagePortCreateRunLoopSource(nil, port, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
    }

    static func probe(name: String = serviceName, timeout: TimeInterval = 0.3) -> RuntimeVersionReply? {
        guard let port = CFMessagePortCreateRemote(nil, name as CFString) else { return nil }
        let nonce = UUID().uuidString
        var result: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(port, 1, Data(nonce.utf8) as CFData, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &result)
        guard status == kCFMessagePortSuccess else { CFMessagePortInvalidate(port); return nil }
        guard let bytes = result?.takeRetainedValue(),
              let reply = try? JSONDecoder().decode(RuntimeVersionReply.self, from: bytes as Data), reply.nonce == nonce else { return nil }
        return reply
    }
}
