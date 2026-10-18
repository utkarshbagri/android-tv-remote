import CryptoKit
import Foundation
import Network

/// Pairing ("polo") protocol on port 6467.
///
///     client → pairing_request          TV → pairing_request_ack
///     client → options                  TV → options
///     client → configuration            TV → configuration_ack   (TV now shows a 6-hex-digit code)
///     client → secret(sha256(...))      TV → secret_ack          (paired: TV trusts our cert)
public final class PairingSession {
    // OuterMessage field numbers (polo.proto)
    private enum F {
        static let version = 1, status = 2
        static let pairingRequest = 10, pairingRequestAck = 11
        static let options = 20, configuration = 30, configurationAck = 31
        static let secret = 40, secretAck = 41
    }
    private static let statusOK: UInt64 = 200

    private let identity: ClientIdentity
    private let clientName: String
    private let queue = DispatchQueue(label: "atv.pairing")
    private let connection: FramedTLSConnection
    private var pending: CheckedContinuation<Void, Error>?
    private var awaiting: Int?   // field number that resolves `pending`
    private var terminalError: Error?  // set once the TV aborts; later exchanges fail fast

    public init(endpoint: NWEndpoint, identity: ClientIdentity, clientName: String = "iPhone Remote") {
        self.identity = identity
        self.clientName = clientName
        self.connection = FramedTLSConnection(endpoint: endpoint, identity: identity, queue: queue)
    }

    public convenience init(host: String, port: UInt16 = 6467, identity: ClientIdentity,
                            clientName: String = "iPhone Remote") {
        self.init(endpoint: .hostPort(host: .init(host), port: .init(rawValue: port)!),
                  identity: identity, clientName: clientName)
    }

    /// Connects and runs the handshake up to the point where the TV displays the pairing code.
    public func start() async throws {
        connection.onFrame = { [weak self] in self?.handle($0) }
        connection.onClose = { [weak self] error in
            self?.fail(ATVError.pairing("connection closed\(error.map { ": \($0)" } ?? "")"))
        }
        try await connection.start()
        try await exchange(awaiting: F.configurationAck) {
            $0.message(F.pairingRequest) { r in
                r.string(1, "atvremote")    // service_name
                r.string(2, self.clientName) // client_name (shown on the TV)
            }
        }
    }

    /// Sends the code shown on the TV. Throws if it is not the code the TV displayed.
    public func finish(code rawCode: String) async throws {
        let code = rawCode.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 6, let codeBytes = Data(hex: code) else {
            throw ATVError.pairing("code must be 6 hex characters")
        }
        guard let client = DER.rsaPublicKey(of: identity.certificate) else {
            throw ATVError.pairing("could not read client public key")
        }
        guard let serverCert = connection.serverCertificate,
              let server = DER.rsaPublicKey(of: serverCert) else {
            throw ATVError.pairing("no server certificate captured")
        }
        var sha = SHA256()
        sha.update(data: client.modulus)
        sha.update(data: client.exponent)
        sha.update(data: server.modulus)
        sha.update(data: server.exponent)
        sha.update(data: codeBytes.dropFirst())   // last 4 hex digits
        let secret = Data(sha.finalize())
        // The first hex byte of the code is a checksum: the first byte of the hash.
        guard secret.first == codeBytes.first else {
            throw ATVError.pairing("wrong code (checksum mismatch) — check the code on the TV")
        }
        try await exchange(awaiting: F.secretAck) {
            $0.message(F.secret) { s in s.bytes(1, secret) }
        }
        connection.cancel()
    }

    public func cancel() { connection.cancel() }

    // MARK: - Internals (all on `queue`)

    private func outer(_ body: (inout ProtoWriter) -> Void) -> Data {
        var w = ProtoWriter()
        w.uint(F.version, 2)
        w.uint(F.status, Self.statusOK)
        body(&w)
        return w.data
    }

    private func exchange(awaiting field: Int, _ body: @escaping (inout ProtoWriter) -> Void) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if let error = self.terminalError { return cont.resume(throwing: error) }
                self.pending = cont
                self.awaiting = field
                let out = self.outer(body)
                ATVLog.debug("pairing → \(out.hexString)")
                self.connection.send(out)
            }
        }
    }

    private func fail(_ error: Error) {
        if terminalError == nil { terminalError = error }
        pending?.resume(throwing: error)
        pending = nil
        awaiting = nil
    }

    private func handle(_ frame: Data) {
        ATVLog.debug("pairing ← \(frame.hexString)")
        guard let msg = try? ProtoMessage(frame) else { return fail(ATVError.pairing("undecodable message")) }
        let status = msg.uint(F.status) ?? 0
        guard status == Self.statusOK else {
            let reason = status == 402 ? "bad secret (wrong code)" : "TV returned status \(status)"
            fail(ATVError.pairing(reason))
            connection.cancel()
            return
        }
        if let awaiting, msg.has(awaiting) {
            pending?.resume()
            pending = nil
            self.awaiting = nil
            return
        }
        // Encoding: hexadecimal, 6 symbols; we are the INPUT side (user types the code).
        let encoding: (inout ProtoWriter) -> Void = { e in e.uint(1, 3); e.uint(2, 6) }
        if msg.has(F.pairingRequestAck) {
            connection.send(outer { $0.message(F.options) { o in
                o.message(1, encoding)  // input_encodings
                o.uint(3, 1)            // preferred_role = ROLE_TYPE_INPUT
            } })
        } else if msg.has(F.options) {
            connection.send(outer { $0.message(F.configuration) { c in
                c.message(1, encoding)  // encoding
                c.uint(2, 1)            // client_role = ROLE_TYPE_INPUT
            } })
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}

/// Debug hook: set `ATVLog.handler` to see protocol traffic.
public enum ATVLog {
    public static var handler: ((String) -> Void)?
    static func debug(_ s: @autoclosure () -> String) { handler?(s()) }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
