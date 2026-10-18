import Foundation

/// Watch ⇄ iPhone messages (WatchConnectivity dictionaries). watchOS won't let the watch app open
/// the TV's TLS socket itself (raw networking is limited to audio/VoIP apps, TN3135), so the watch
/// sends commands to the iPhone app, which holds the remote connection.
enum WatchMessage {
    // Watch → iPhone: "cmd" plus arguments.
    static let cmd = "cmd"
    static let key = "key"          // cmd: send KeyCode raw value `code`, `count` times
    static let app = "app"          // cmd: open streaming app `id`
    static let title = "title"      // cmd: open search result `url` (`name`, app `id`)
    static let relaunch = "relaunch" // cmd: re-send the pending title link
    static let state = "state"      // cmd: just reply with state

    static let code = "code", count = "count", id = "id", url = "url", name = "name"

    // iPhone → watch state (reply to every command, and pushed on change).
    static let connected = "connected", device = "device", nowOn = "nowOn", package = "package"
    static let volume = "volume", volumeMax = "volumeMax", muted = "muted", pending = "pending"
}
