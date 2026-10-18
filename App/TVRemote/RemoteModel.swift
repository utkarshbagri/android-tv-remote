import ATVRemoteKit
import Foundation
import SwiftUI

@MainActor
final class RemoteModel: ObservableObject {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case needsPairing
        case awaitingCode
        case connected
    }

    @Published var phase: Phase = .disconnected
    @Published var host: String = UserDefaults.standard.string(forKey: "host") ?? "192.168.1.128" {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var discovered: [TVDiscovery.Found] = []
    @Published var deviceName = ""
    @Published var currentApp = ""
    @Published var volume = ""
    @Published var log: [String] = []

    private var remote: RemoteSession?
    private var pairing: PairingSession?
    private let discovery = TVDiscovery()

    init() {
        discovery.onChange = { [weak self] found in
            Task { @MainActor in self?.discovered = found }
        }
    }

    func startDiscovery() { discovery.start() }

    func select(_ tv: TVDiscovery.Found) {
        Task {
            if let ip = await TVDiscovery.resolveHost(tv.endpoint) {
                host = ip
                note("Resolved \(tv.name) → \(ip)")
                connect()
            } else {
                note("Could not resolve \(tv.name)")
            }
        }
    }

    func connect() {
        remote?.disconnect()
        phase = .connecting
        Task {
            do {
                let identity = try ClientIdentity.loadOrCreate()
                let session = RemoteSession(host: host, identity: identity)
                session.onEvent = { [weak self] event in
                    Task { @MainActor in self?.handle(event, from: session) }
                }
                try await session.connect()
                remote = session
                phase = .connected
                note("Connected to \(host)")
            } catch {
                // An unpaired client cert is rejected during/just after the TLS handshake.
                note("Connect failed: \(error.localizedDescription)")
                phase = .needsPairing
            }
        }
    }

    func startPairing() {
        Task {
            do {
                let identity = try ClientIdentity.loadOrCreate()
                let session = PairingSession(host: host, identity: identity, clientName: "iPhone Remote")
                pairing = session
                try await session.start()
                phase = .awaitingCode
                note("Enter the code shown on the TV")
            } catch {
                note("Pairing failed: \(error.localizedDescription)")
                phase = .needsPairing
            }
        }
    }

    func submit(code: String) {
        guard let pairing else { return }
        Task {
            do {
                try await pairing.finish(code: code)
                self.pairing = nil
                note("Paired")
                connect()
            } catch {
                note("Pairing failed: \(error.localizedDescription)")
                pairing.cancel()
                self.pairing = nil
                phase = .needsPairing
            }
        }
    }

    func cancelPairing() {
        pairing?.cancel()
        pairing = nil
        phase = .needsPairing
    }

    func forgetIdentity() {
        remote?.disconnect()
        remote = nil
        ClientIdentity.reset()
        phase = .needsPairing
        note("Client certificate deleted — pair again")
    }

    func press(_ key: KeyCode) {
        remote?.sendKey(key)
    }

    func open(_ link: String) {
        guard let remote else { return }
        remote.launch(appLink: link)
        note("Opened \(link)")
    }

    private func handle(_ event: RemoteEvent, from session: RemoteSession) {
        switch event {
        case let .ready(model, vendor): deviceName = "\(vendor) \(model)"
        case let .currentApp(pkg): currentApp = pkg
        case let .volume(level, max, muted): volume = muted ? "muted" : "\(level)/\(max)"
        case .poweredOn: break
        case let .error(message): note(message)
        case let .disconnected(reason):
            // Ignore late events from a session we already replaced.
            guard session === remote else { return }
            remote = nil
            phase = .disconnected
            note("Disconnected\(reason.map { ": \($0)" } ?? "")")
        }
    }

    private func note(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
