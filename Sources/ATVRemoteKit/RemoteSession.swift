import Foundation
import Network

/// Android key codes accepted by RemoteKeyInject (subset of remotemessage.proto's RemoteKeyCode).
public enum KeyCode: Int, CaseIterable {
    case home = 3, back = 4
    case dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22, dpadCenter = 23
    case volumeUp = 24, volumeDown = 25, power = 26
    case menu = 82, search = 84, playPause = 85
    case mediaNext = 87, mediaPrevious = 88, rewind = 89, fastForward = 90, mute = 91
}

public enum KeyDirection: Int {
    case startLong = 1, endLong = 2, short = 3
}

public enum RemoteEvent {
    case ready(model: String, vendor: String)
    case poweredOn(Bool)
    case currentApp(String)
    case volume(level: Int, max: Int, muted: Bool)
    case error(String)
    case disconnected(String?)
}

/// Remote-control protocol on port 6466. Requires a paired ClientIdentity: an unpaired cert is
/// rejected by the TV during the TLS handshake.
public final class RemoteSession {
    // RemoteMessage field numbers (remotemessage.proto)
    private enum F {
        static let configure = 1, setActive = 2, error = 3
        static let pingRequest = 8, pingResponse = 9, keyInject = 10
        static let imeKeyInject = 20, start = 40, setVolume = 50, appLink = 90
    }
    // Feature bits: PING | KEY | IME | POWER | VOLUME | APP_LINK
    private static let features: UInt64 = 1 | 2 | 4 | 32 | 64 | 512

    public var onEvent: ((RemoteEvent) -> Void)?

    private let queue = DispatchQueue(label: "atv.remote")
    private let connection: FramedTLSConnection
    private var activeFeatures = RemoteSession.features
    private var startWaiter: CheckedContinuation<Void, Error>?

    public init(endpoint: NWEndpoint, identity: ClientIdentity) {
        connection = FramedTLSConnection(endpoint: endpoint, identity: identity, queue: queue)
    }

    public convenience init(host: String, port: UInt16 = 6466, identity: ClientIdentity) {
        self.init(endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!), identity: identity)
    }

    /// Connects and waits until the TV says it is ready for commands (remote_start).
    public func connect() async throws {
        connection.onFrame = { [weak self] in self?.handle($0) }
        connection.onClose = { [weak self] error in
            guard let self else { return }
            self.startWaiter?.resume(throwing: ATVError.connection(
                "closed before ready — not paired? \(error.map { "\($0)" } ?? "")"))
            self.startWaiter = nil
            self.onEvent?(.disconnected(error.map { "\($0)" }))
        }
        try await connection.start()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { self.startWaiter = cont }
        }
        // Key events sent right after remote_start are silently dropped by the TV (observed on
        // the Acer R4: dropped at 0ms, delivered at 300ms+), so settle briefly before returning.
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    public func sendKey(_ key: KeyCode, direction: KeyDirection = .short) {
        send { $0.message(F.keyInject) { k in
            k.uint(1, UInt64(key.rawValue))
            k.uint(2, UInt64(direction.rawValue))
        } }
    }

    /// Asks the TV to open a deep link (Android intent with ACTION_VIEW on the URI).
    public func launch(appLink: String) {
        send { $0.message(F.appLink) { a in a.string(1, appLink) } }
    }

    public func disconnect() {
        connection.cancel()
    }

    private func send(_ body: @escaping (inout ProtoWriter) -> Void) {
        queue.async {
            var w = ProtoWriter()
            body(&w)
            self.connection.send(w.data)
        }
    }

    private func handle(_ frame: Data) {
        guard let msg = try? ProtoMessage(frame) else { return }
        if let cfg = msg.message(F.configure) {
            let supported = cfg.uint(1) ?? 0
            activeFeatures = Self.features & supported
            let info = cfg.message(2)
            onEvent?(.ready(model: info?.string(1) ?? "?", vendor: info?.string(2) ?? "?"))
            send { [activeFeatures] w in w.message(F.configure) { c in
                c.uint(1, activeFeatures)
                c.message(2) { d in
                    d.int(3, 1)               // unknown1
                    d.string(4, "1")          // unknown2
                    d.string(5, "atvremote")  // package_name
                    d.string(6, "1.0.0")      // app_version
                }
            } }
        } else if msg.has(F.setActive) {
            send { [activeFeatures] w in w.message(F.setActive) { $0.uint(1, activeFeatures) } }
        } else if let ping = msg.message(F.pingRequest) {
            let val = ping.uint(1) ?? 0
            send { $0.message(F.pingResponse) { $0.uint(1, val) } }
        } else if let start = msg.message(F.start) {
            startWaiter?.resume()
            startWaiter = nil
            onEvent?(.poweredOn(start.uint(1) == 1))
        } else if let ime = msg.message(F.imeKeyInject),
                  let pkg = ime.message(1)?.string(12) {
            onEvent?(.currentApp(pkg))
        } else if let vol = msg.message(F.setVolume) {
            onEvent?(.volume(level: Int(vol.uint(7) ?? 0), max: Int(vol.uint(6) ?? 0),
                             muted: vol.uint(8) == 1))
        } else if msg.has(F.error) {
            onEvent?(.error("TV reported an error: \(frame.map { String(format: "%02x", $0) }.joined())"))
        }
    }
}
