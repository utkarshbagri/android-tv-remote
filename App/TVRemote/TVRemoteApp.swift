import SwiftUI

@main
struct TVRemoteApp: App {
    init() {
        // Before any scene: a watch command can launch the app straight into the background.
        WatchBridge.shared.activate(model: RemoteModel.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
