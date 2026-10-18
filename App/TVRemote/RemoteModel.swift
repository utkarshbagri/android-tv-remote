import ATVRemoteKit
import Foundation
import SwiftUI

@MainActor
final class RemoteModel: ObservableObject {
    /// One model for the app's lifetime: the watch relay can wake the app in the background
    /// before any view exists.
    static let shared = RemoteModel()

    enum Phase: Equatable {
        case connecting, connected, needsPairing, awaitingCode, offline(String)
    }

    @Published var phase: Phase = .connecting
    @Published var host: String = UserDefaults.standard.string(forKey: "host") ?? "192.168.1.128" {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var discovered: [TVDiscovery.Found] = []
    @Published var deviceName = "Android TV"
    @Published var currentPackage = ""
    @Published var volume = 0
    @Published var volumeMax = 100
    @Published var muted = false
    @Published var log: [String] = []

    // Search
    @Published var searchText = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    @Published var results: [JustWatch.Title] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var toast: String?
    @Published var pendingRelaunch: PendingLink?
    private var searchTask: Task<Void, Never>?

    private var remote: RemoteSession?
    private var pairing: PairingSession?
    private let discovery = TVDiscovery()
    private var retryDelay: UInt64 = 2
    private var connectTask: Task<Void, Never>?

    var isConnected: Bool { phase == .connected }
    var currentAppName: String { appName(forPackage: currentPackage) }

    private init() {
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

    /// Connects unless already connected/connecting (app launch, back to foreground).
    func ensureConnected() {
        switch phase {
        case .connected, .awaitingCode: return
        case .connecting where connectTask != nil: return
        default: connect()
        }
    }

    func connect() {
        connectTask?.cancel()
        remote?.disconnect()
        remote = nil
        phase = .connecting
        connectTask = Task {
            defer { connectTask = nil }
            do {
                let identity = try ClientIdentity.loadOrCreate()
                let session = RemoteSession(host: host, identity: identity)
                session.onEvent = { [weak self] event in
                    Task { @MainActor in self?.handle(event, from: session) }
                }
                try await session.connect()
                remote = session
                phase = .connected
                retryDelay = 2
                note("Connected to \(host)")
            } catch {
                let message = error.localizedDescription
                note("Connect failed: \(message)")
                // An unpaired client cert is rejected during/just after the TLS handshake.
                if message.contains("certificate") || message.contains("not paired") {
                    phase = .needsPairing
                } else {
                    phase = .offline(message)
                    scheduleRetry()
                }
            }
        }
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        Task {
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            if case .offline = phase { connect() }
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
                phase = .offline("Pairing: \(error.localizedDescription)")
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
        // OK on a "Who's watching?" screen: the cold start may have dropped the deep link, so
        // send it again once the profile has loaded.
        if key == .dpadCenter, let pending = pendingRelaunch {
            pendingRelaunch = nil
            Task {
                try? await Task.sleep(nanoseconds: PendingLink.resendDelay)
                remote?.launch(appLink: pending.url)
                show("Opening \(pending.title)…")
            }
        }
    }

    /// Waits (briefly) for the TV connection, connecting if needed. For watch commands that may
    /// arrive while the app was suspended and its socket dropped.
    func connectedRemote(timeout: TimeInterval = 6) async -> Bool {
        ensureConnected()
        let deadline = Date().addingTimeInterval(timeout)
        while phase != .connected, Date() < deadline {
            if phase == .needsPairing { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return phase == .connected
    }

    /// Re-sends the last title link (for profiles picked with the TV's own remote).
    func relaunchPending() {
        guard let pending = pendingRelaunch, let remote else { return }
        pendingRelaunch = nil
        remote.launch(appLink: pending.url)
        show("Opening \(pending.title)…")
    }

    /// Opens a search result on the TV.
    func open(_ offer: JustWatch.Offer, title: String) {
        guard let remote else { return }
        remote.launch(appLink: offer.url)
        note("Opened \(offer.url)")
        show("Opening \(title) on \(offer.app.name)…")
        if let pending = PendingLink(offer: offer, title: title) {
            pendingRelaunch = pending
            Task {
                try? await Task.sleep(nanoseconds: PendingLink.promptWindow)
                if pendingRelaunch == pending { pendingRelaunch = nil }
            }
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == message { toast = nil }
        }
    }

    /// Debounced JustWatch search as the user types.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = []
            searching = false
            searchError = nil
            return
        }
        searching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await JustWatch.search(text)
                guard !Task.isCancelled else { return }
                results = found
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Search failed: \(error.localizedDescription)"
            }
            searching = false
        }
    }

    func open(_ app: StreamingApp) {
        remote?.launch(appLink: app.link)
    }

    /// The protocol has no "set volume", so step towards the target with volume keys.
    func setVolume(_ target: Int) {
        let delta = target - volume
        guard delta != 0, let remote else { return }
        let key: KeyCode = delta > 0 ? .volumeUp : .volumeDown
        Task {
            for _ in 0..<min(abs(delta), 50) {
                remote.sendKey(key)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
    }

    func open(_ link: String) {
        guard let remote else { return }
        remote.launch(appLink: link)
        note("Opened \(link)")
    }

    private func handle(_ event: RemoteEvent, from session: RemoteSession) {
        switch event {
        case let .ready(model, vendor): deviceName = vendor == "?" ? model : "\(vendor) \(model)"
        case let .currentApp(pkg): currentPackage = pkg
        case let .volume(level, max, isMuted):
            volume = level
            volumeMax = max == 0 ? 100 : max
            muted = isMuted
        case .poweredOn: break
        case let .error(message): note(message)
        case let .disconnected(reason):
            // Ignore late events from a session we already replaced.
            guard session === remote else { return }
            remote = nil
            phase = .offline(reason ?? "Disconnected")
            note("Disconnected\(reason.map { ": \($0)" } ?? "")")
            scheduleRetry()
        }
    }

    private func note(_ s: String) {
        log.insert(s, at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
