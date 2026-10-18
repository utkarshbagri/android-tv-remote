import SwiftUI

@main
struct TVRemoteBarApp: App {
    @StateObject private var model = BarModel()

    init() {
        // `TVRemoteBar --snapshot out.png` renders the panel (offline, sample state) for design review.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            MainActor.assumeIsolated { Snapshot.render(to: args[i + 1]) }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            Image(systemName: model.isConnected ? "tv.fill" : "tv")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum Snapshot {
    static func render(to path: String) {
        let model = BarModel(autoConnect: false)
        model.phase = .connected
        model.deviceName = "Scbc R4"
        model.currentPackage = "com.netflix.ninja"
        model.volume = 22
        let renderer = ImageRenderer(content: PanelView(model: model))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
