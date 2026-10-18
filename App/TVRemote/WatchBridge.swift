import ATVRemoteKit
import Combine
import Foundation
import WatchConnectivity

/// Runs Apple Watch commands against the TV connection and keeps the watch's state readout fresh.
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private var model: RemoteModel?
    private var changes: AnyCancellable?

    func activate(model: RemoteModel) {
        guard WCSession.isSupported() else { return }
        self.model = model
        WCSession.default.delegate = self
        WCSession.default.activate()
        // Push state to the watch when it changes (debounced; only while the watch app is up).
        changes = model.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.pushState() }
    }

    @MainActor private func state() -> [String: Any] {
        guard let model else { return [:] }
        var s: [String: Any] = [
            WatchMessage.connected: model.isConnected,
            WatchMessage.device: model.deviceName,
            WatchMessage.nowOn: model.currentAppName,
            WatchMessage.package: model.currentPackage,
            WatchMessage.volume: model.volume,
            WatchMessage.volumeMax: model.volumeMax,
            WatchMessage.muted: model.muted,
        ]
        if let pending = model.pendingRelaunch { s[WatchMessage.pending] = pending.appName }
        return s
    }

    private func pushState() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        Task { @MainActor in
            let s = state()
            // Live message when the watch app is up; application context as the durable fallback.
            if session.isReachable { session.sendMessage(s, replyHandler: nil, errorHandler: nil) }
            try? session.updateApplicationContext(s)
        }
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            await handle(message)
            replyHandler(state())
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in await handle(message) }
    }

    @MainActor private func handle(_ message: [String: Any]) async {
        guard let model, let cmd = message[WatchMessage.cmd] as? String else { return }
        guard await model.connectedRemote() else { return }
        switch cmd {
        case WatchMessage.key:
            guard let raw = message[WatchMessage.code] as? Int, let key = KeyCode(rawValue: raw) else { return }
            let count = min(max(message[WatchMessage.count] as? Int ?? 1, 1), 50)
            for i in 0..<count {
                if i > 0 { try? await Task.sleep(nanoseconds: 40_000_000) }
                model.press(key)
            }
        case WatchMessage.app:
            if let id = message[WatchMessage.id] as? String, let app = streamingApps.first(where: { $0.id == id }) {
                model.open(app)
            }
        case WatchMessage.title:
            guard let id = message[WatchMessage.id] as? String,
                  let app = streamingApps.first(where: { $0.id == id }),
                  let url = message[WatchMessage.url] as? String,
                  let name = message[WatchMessage.name] as? String else { return }
            model.open(JustWatch.Offer(app: app, url: url, label: ""), title: name)
        case WatchMessage.relaunch:
            model.relaunchPending()
        default:
            break
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
}
