import ATVRemoteKit
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

// AppKit status item + floating panel instead of SwiftUI's MenuBarExtra, so the panel can also be
// opened when the icon is hidden behind the notch on a crowded menu bar: via the ⌃⌥T hotkey, or by
// opening "TV Remote" again (Spotlight/Finder sends a reopen event to the running app).

@main
enum TVRemoteBarMain {
    static func main() {
        let args = CommandLine.arguments
        // `TVRemoteBar --snapshot out.png` renders the panel (offline, sample state) for design review.
        // `--snapshot out.png "query"` renders the search results for that query instead.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let query = i + 2 < args.count ? args[i + 2] : nil
            Task { @MainActor in
                await Snapshot.render(to: args[i + 1], query: query)
                exit(0)
            }
            RunLoop.main.run()
            return
        }
        let app = NSApplication.shared
        let delegate = MainActor.assumeIsolated { AppDelegate() }
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = BarModel()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var hotKey: EventHotKeyRef?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "TVRemoteStatusItem"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        model.$phase
            .sink { [weak self] phase in
                let name = phase == .connected ? "tv.fill" : "tv"
                self?.statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "TV Remote")
            }
            .store(in: &cancellables)

        panel = NSPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: PanelView(model: model))
        panel.contentView = host
        panel.setContentSize(host.fittingSize)

        registerHotKey()
    }

    /// Opening the app again (Spotlight, Finder, `open`) toggles the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePanel()
        return false
    }

    /// Close when the user clicks elsewhere, like a menu.
    func windowDidResignKey(_ notification: Notification) {
        panel.orderOut(nil)
    }

    @objc func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        model.ensureConnected()
        if let size = panel.contentView?.fittingSize { panel.setContentSize(size) }
        panel.setFrameTopLeftPoint(anchorPoint())
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Under the status item when it's on screen; otherwise top-right of the active screen
    /// (the item is "hidden" behind the notch when its window sits off the visible frame).
    private func anchorPoint() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let width = panel.frame.width
        if let buttonWindow = statusItem.button?.window,
           buttonWindow.frame.minX >= screen.frame.minX, buttonWindow.frame.maxX <= screen.frame.maxX,
           buttonWindow.isVisible, buttonWindow.occlusionState.contains(.visible) {
            let x = min(max(buttonWindow.frame.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
            return NSPoint(x: x, y: visible.maxY - 6)
        }
        return NSPoint(x: visible.maxX - width - 12, y: visible.maxY - 6)
    }

    private func registerHotKey() {
        // ⌃⌥T
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { delegate.togglePanel() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x5456_5242), id: 1)  // 'TVRB'
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }
}

@MainActor
enum Snapshot {
    static var active = false
    static var posters: [URL: NSImage] = [:]

    static func render(to path: String, query: String? = nil) async {
        active = true
        let model = BarModel(autoConnect: false)
        model.phase = .connected
        model.deviceName = "SCBC R4"
        model.currentPackage = "com.netflix.ninja"
        model.volume = 22
        if let query {
            model.searchText = query
            // Top 4 results with posters preloaded (the panel shows about that many).
            model.results = Array(((try? await JustWatch.search(query)) ?? []).filter { !$0.offers.isEmpty }.prefix(4))
            for title in model.results {
                guard let url = title.poster, let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { continue }
                posters[url] = image
            }
            model.searching = false
            FileHandle.standardError.write(Data("results: \(model.results.count)\n".utf8))
        }
        let renderer = ImageRenderer(content: PanelView(model: model))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
