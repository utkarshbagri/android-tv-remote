import Foundation
import Network
import Security

/// TLS connection (client cert = our self-signed identity, server cert accepted blindly but
/// captured) carrying varint-length-prefixed protobuf frames. Both the pairing port (6467) and the
/// remote port (6466) use this framing. All callbacks fire on `queue`.
final class FramedTLSConnection {
    let queue: DispatchQueue
    private let connection: NWConnection
    private var frames = FrameBuffer()
    private(set) var serverCertificate: SecCertificate?

    var onFrame: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(endpoint: NWEndpoint, identity: ClientIdentity, queue: DispatchQueue) {
        self.queue = queue
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        if let secIdentity = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(sec, secIdentity)
        }
        // The TV presents a self-signed cert. We accept it but keep it: pairing hashes its key.
        var captured: SecCertificate?
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate] {
                captured = chain.first
            }
            complete(true)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
        // The verify block runs before .ready; copy the capture onto self once ready.
        captureServerCert = { captured }
    }

    private var captureServerCert: () -> SecCertificate? = { nil }

    /// Connects and completes the TLS handshake.
    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.serverCertificate = self.captureServerCert()
                    if !resumed { resumed = true; cont.resume() }
                    self.receive()
                case .waiting(let error), .failed(let error):
                    if !resumed {
                        resumed = true
                        cont.resume(throwing: ATVError.connection(error.localizedDescription))
                    }
                    self.connection.cancel()
                    self.onClose?(error)
                case .cancelled:
                    if !resumed { resumed = true; cont.resume(throwing: ATVError.connection("cancelled")) }
                    self.onClose?(nil)
                    self.onClose = nil
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ message: Data) {
        connection.send(content: ProtoWriter.varint(UInt64(message.count)) + message,
                        completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.frames.append(data)
                while let frame = self.frames.next() { self.onFrame?(frame) }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }
}
