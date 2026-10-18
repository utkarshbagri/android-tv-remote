import ATVRemoteKit
import Foundation
import WatchConnectivity

/// Watch-side state. Every action is a message to the iPhone app, which talks to the TV.
@MainActor
final class WatchModel: NSObject, ObservableObject {
    @Published var reachable = false
    @Published var connected = false
    @Published var device = "TV"
    @Published var nowOn = "—"
    @Published var package = ""
    @Published var volume = 0
    @Published var volumeMax = 100
    @Published var muted = false
    @Published var pending: String?
    @Published var lastError: String?

    // Search
    @Published var results: [JustWatch.Title] = []
    @Published var searching = false
    @Published var searchError: String?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func refresh() { send([WatchMessage.cmd: WatchMessage.state]) }

    func press(_ key: KeyCode, count: Int = 1) {
        send([WatchMessage.cmd: WatchMessage.key, WatchMessage.code: key.rawValue, WatchMessage.count: count])
    }

    func open(_ app: StreamingApp) {
        send([WatchMessage.cmd: WatchMessage.app, WatchMessage.id: app.id])
    }

    func open(_ offer: JustWatch.Offer, title: String) {
        send([WatchMessage.cmd: WatchMessage.title, WatchMessage.id: offer.app.id,
              WatchMessage.url: offer.url, WatchMessage.name: title])
    }

    func relaunch() { send([WatchMessage.cmd: WatchMessage.relaunch]) }

    /// Steps the volume locally right away (the crown feels instant) and sends the keys.
    func nudgeVolume(by steps: Int) {
        guard steps != 0 else { return }
        volume = min(max(volume + steps, 0), volumeMax)
        press(steps > 0 ? .volumeUp : .volumeDown, count: abs(steps))
    }

    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; return }
        searching = true
        searchError = nil
        Task {
            do {
                results = try await JustWatch.search(text)
            } catch {
                searchError = error.localizedDescription
            }
            searching = false
        }
    }

    private var followUp: Task<Void, Never>?

    private func send(_ message: [String: Any]) {
        post(message)
        // The TV reports a new foreground app/volume a moment after the key lands, after the reply.
        guard message[WatchMessage.cmd] as? String != WatchMessage.state else { return }
        followUp?.cancel()
        followUp = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func post(_ message: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        session.sendMessage(message, replyHandler: { reply in
            Task { @MainActor in
                self.lastError = nil
                self.apply(reply)
            }
        }, errorHandler: { error in
            Task { @MainActor in self.lastError = "iPhone not reachable" }
        })
    }

    private func apply(_ s: [String: Any]) {
        if let v = s[WatchMessage.connected] as? Bool { connected = v }
        if let v = s[WatchMessage.device] as? String { device = v }
        if let v = s[WatchMessage.nowOn] as? String { nowOn = v }
        if let v = s[WatchMessage.package] as? String { package = v }
        if let v = s[WatchMessage.volume] as? Int { volume = v }
        if let v = s[WatchMessage.volumeMax] as? Int { volumeMax = max(v, 1) }
        if let v = s[WatchMessage.muted] as? Bool { muted = v }
        if s[WatchMessage.connected] != nil { pending = s[WatchMessage.pending] as? String }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            reachable = session.isReachable
            apply(session.receivedApplicationContext)
            refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            reachable = session.isReachable
            if session.isReachable { refresh() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in apply(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in apply(context) }
    }
}
