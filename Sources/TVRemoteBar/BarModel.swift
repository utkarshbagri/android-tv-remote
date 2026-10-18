import ATVRemoteKit
import Foundation
import SwiftUI

/// Streaming apps we can open from the panel. Links are the "app home" URLs each TV app's intent
/// filters claim (verified on the Acer R4, see docs/DEEPLINKS.md). F1 TV declares no deep links
/// and can't be launched over the remote protocol, so it isn't here.
struct StreamingApp: Identifiable, Hashable {
    let id: String          // Android package
    let name: String
    let symbol: String
    let link: String

    /// Compact label for result chips.
    var shortName: String { name == "Prime Video" ? "Prime" : name }
}

let streamingApps: [StreamingApp] = [
    .init(id: "com.netflix.ninja", name: "Netflix", symbol: "n.square.fill",
          link: "https://www.netflix.com/browse"),
    .init(id: "com.amazon.amazonvideo.livingroom", name: "Prime Video", symbol: "play.square.fill",
          link: "https://app.primevideo.com/"),
    .init(id: "in.startv.hotstar", name: "JioHotstar", symbol: "star.square.fill",
          link: "https://www.hotstar.com/in/home"),
    .init(id: "com.google.android.youtube.tv", name: "YouTube", symbol: "play.rectangle.fill",
          link: "https://www.youtube.com/"),
    .init(id: "com.sonyliv", name: "SonyLIV", symbol: "s.square.fill",
          link: "https://www.sonyliv.com/"),
    .init(id: "com.apple.atve.androidtv.appletv", name: "Apple TV", symbol: "appletv.fill",
          link: "https://tv.apple.com/"),
]

private let knownPackages: [String: String] = Dictionary(
    uniqueKeysWithValues: streamingApps.map { ($0.id, $0.name) } + [
        ("com.formulaone.production", "F1 TV"),
        ("com.gathin.tvhome", "Home"),
        ("com.google.android.youtube.tvmusic", "YouTube Music"),
    ])

@MainActor
final class BarModel: ObservableObject {
    enum Phase: Equatable {
        case connecting, connected, needsPairing, awaitingCode, offline(String)
    }

    @Published var phase: Phase = .connecting
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "192.168.1.128" {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var deviceName = "Android TV"
    @Published var currentPackage = ""
    @Published var volume = 0
    @Published var volumeMax = 100
    @Published var muted = false
    @Published var isOn = true

    // Search
    @Published var searchText = "" {
        didSet { scheduleSearch() }
    }
    @Published var results: [JustWatch.Title] = []
    @Published var searching = false
    @Published var searchError: String?
    @Published var toast: String?
    @Published var pendingRelaunch: PendingLink?

    struct PendingLink: Equatable {
        let url: String
        let title: String
        let appName: String
    }

    static let profileGatedApps: Set<String> = [
        "com.netflix.ninja", "com.apple.atve.androidtv.appletv", "com.amazon.amazonvideo.livingroom",
    ]
    private var searchTask: Task<Void, Never>?

    private var remote: RemoteSession?
    private var pairing: PairingSession?
    private var retryDelay: UInt64 = 2
    private var connectTask: Task<Void, Never>?

    init(autoConnect: Bool = true) {
        // Connect at launch so the menu-bar icon reflects state before the panel is first opened.
        if autoConnect { Task { @MainActor in self.connect() } }
    }

    var currentAppName: String {
        if currentPackage.isEmpty { return "—" }
        return knownPackages[currentPackage] ?? currentPackage.components(separatedBy: ".").last ?? currentPackage
    }

    var isConnected: Bool { phase == .connected }

    /// Connects unless already connected/connecting. Safe to call whenever the panel opens.
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
            } catch {
                let message = error.localizedDescription
                // TLS accepted but the TV refused our cert → it doesn't know us yet.
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
                let session = PairingSession(host: host, identity: identity, clientName: "Mac menu bar")
                pairing = session
                try await session.start()
                phase = .awaitingCode
            } catch {
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
                connect()
            } catch {
                pairing.cancel()
                self.pairing = nil
                phase = .offline(error.localizedDescription)
            }
        }
    }

    func cancelPairing() {
        pairing?.cancel()
        pairing = nil
        phase = .needsPairing
    }

    func press(_ key: KeyCode) {
        remote?.sendKey(key)
        // OK on a "Who's watching?" screen: the cold start may have dropped the deep link, so
        // send it again once the profile has loaded.
        if key == .dpadCenter, let pending = pendingRelaunch {
            pendingRelaunch = nil
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                remote?.launch(appLink: pending.url)
                show("Opening \(pending.title)…")
            }
        }
    }

    /// Re-sends the last title link (footer button, for profiles picked with the TV's own remote).
    func relaunchPending() {
        guard let pending = pendingRelaunch, let remote else { return }
        pendingRelaunch = nil
        remote.launch(appLink: pending.url)
        show("Opening \(pending.title)…")
    }

    func open(_ app: StreamingApp) {
        remote?.launch(appLink: app.link)
    }

    /// Opens a title link (from search) on the TV.
    func open(_ offer: JustWatch.Offer, title: String) {
        guard let remote else { return }
        remote.launch(appLink: offer.url)
        show("Opening \(title) on \(offer.app.name)…")
        // Apps with a "Who's watching?" picker can drop the deep link on a cold start (Netflix and
        // Apple TV, reported by the user), so offer a re-send for 90s. Re-sending once the
        // title page is already showing is harmless.
        if Self.profileGatedApps.contains(offer.app.id) {
            let pending = PendingLink(url: offer.url, title: title, appName: offer.app.shortName)
            pendingRelaunch = pending
            Task {
                try? await Task.sleep(nanoseconds: 90_000_000_000)
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
                // Keep JustWatch's relevance order, but titles we can't open go last.
                results = found.filter { !$0.offers.isEmpty } + found.filter { $0.offers.isEmpty }
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                searchError = "Search failed: \(error.localizedDescription)"
            }
            searching = false
        }
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

    private func handle(_ event: RemoteEvent, from session: RemoteSession) {
        switch event {
        case let .ready(model, vendor):
            deviceName = vendor == "?" ? model : "\(vendor) \(model)"
        case let .currentApp(pkg):
            currentPackage = pkg
        case let .volume(level, max, isMuted):
            volume = level
            volumeMax = max == 0 ? 100 : max
            muted = isMuted
        case let .poweredOn(on):
            isOn = on
        case .error:
            break
        case let .disconnected(reason):
            guard session === remote else { return }
            remote = nil
            phase = .offline(reason ?? "Disconnected")
            scheduleRetry()
        }
    }
}
