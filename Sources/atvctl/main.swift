import ATVRemoteKit
import Foundation
import Security

// atvctl — exercise ATVRemoteKit against a real TV from the Mac.
//   atvctl discover
//   atvctl pair   <host>                (then type the code shown on the TV)
//   atvctl key    <host> <key> [key...]  (up down left right ok back home volup voldown mute ...)
//   atvctl launch <host> <url>
//   atvctl reset                         (delete the client identity from the Keychain)

let keyNames: [String: KeyCode] = [
    "up": .dpadUp, "down": .dpadDown, "left": .dpadLeft, "right": .dpadRight, "ok": .dpadCenter,
    "back": .back, "home": .home, "volup": .volumeUp, "voldown": .volumeDown, "mute": .mute,
    "power": .power, "play": .playPause, "menu": .menu,
]

func log(_ s: String) {
    FileHandle.standardError.write(Data("[atvctl] \(s)\n".utf8))
}

func connectRemote(_ host: String) async throws -> RemoteSession {
    let identity = try ClientIdentity.loadOrCreate()
    // "host" or "host:port" (port override is handy for pointing at a local openssl s_server).
    let parts = host.split(separator: ":")
    let remote = parts.count == 2
        ? RemoteSession(host: String(parts[0]), port: UInt16(parts[1])!, identity: identity)
        : RemoteSession(host: host, identity: identity)
    remote.onEvent = { event in log("event: \(event)") }
    try await remote.connect()
    return remote
}

func run() async throws {
    if ProcessInfo.processInfo.environment["ATV_DEBUG"] != nil { ATVLog.handler = log }
    let args = Array(CommandLine.arguments.dropFirst())
    guard let cmd = args.first else {
        print("usage: atvctl discover | pair <host> | key <host> <key>... | launch <host> <url> | reset")
        exit(2)
    }
    switch cmd {
    case "discover":
        let d = TVDiscovery()
        d.onChange = { found in
            for f in found {
                Task { print("\(f.name) -> \(await TVDiscovery.resolveHost(f.endpoint) ?? "?")") }
            }
        }
        d.start()
        try await Task.sleep(nanoseconds: 4_000_000_000)

    case "export":
        // Debug: dump the client cert + private key so openssl s_client can test the TV directly.
        let identity = try ClientIdentity.loadOrCreate()
        var key: SecKey?
        SecIdentityCopyPrivateKey(identity.identity, &key)
        var err: Unmanaged<CFError>?
        let keyDER = key.flatMap { SecKeyCopyExternalRepresentation($0, &err) as Data? }
        let certDER = SecCertificateCopyData(identity.certificate) as Data
        try certDER.write(to: URL(fileURLWithPath: args[1] + "/client.crt.der"))
        try keyDER?.write(to: URL(fileURLWithPath: args[1] + "/client.key.der"))
        print("exported cert, key=\(keyDER != nil) \(err.map { "\($0.takeRetainedValue())" } ?? "")")

    case "reset":
        ClientIdentity.reset()
        print("identity removed")

    case "pair":
        let identity = try ClientIdentity.loadOrCreate()
        let session = PairingSession(host: args[1], identity: identity, clientName: "atvctl (Mac)")
        try await session.start()
        print("Code is on the TV. Enter it:")
        fflush(stdout)
        guard let code = readLine() else { exit(1) }
        try await session.finish(code: code)
        print("PAIRED")

    case "key":
        let remote = try await connectRemote(args[1])
        if let ms = ProcessInfo.processInfo.environment["ATV_KEY_DELAY_MS"].flatMap(UInt64.init) {
            try await Task.sleep(nanoseconds: ms * 1_000_000)
        }
        for name in args.dropFirst(2) {
            guard let key = keyNames[name.lowercased()] else { log("unknown key \(name)"); continue }
            remote.sendKey(key)
            log("sent \(name)")
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        remote.disconnect()

    case "launch":
        let remote = try await connectRemote(args[1])
        remote.launch(appLink: args[2])
        log("launched \(args[2])")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        remote.disconnect()

    default:
        print("unknown command \(cmd)")
        exit(2)
    }
}

do {
    try await run()
    exit(0)
} catch {
    log("error: \(error.localizedDescription)")
    exit(1)
}
