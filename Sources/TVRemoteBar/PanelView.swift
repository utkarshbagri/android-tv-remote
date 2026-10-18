import ATVRemoteKit
import SwiftUI

// Palette: near-black panel, graphite tiles, warm beige accent (after the AC-remote widget).
private enum Palette {
    static let panel = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let tile = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let tileHi = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let accent = Color(red: 0.85, green: 0.80, blue: 0.71)
    static let accentDeep = Color(red: 0.52, green: 0.48, blue: 0.41)
    static let secondary = Color.white.opacity(0.55)
}

struct PanelView: View {
    @ObservedObject var model: BarModel
    @State private var code = ""
    @State private var showSettings = false
    @FocusState private var focused: Bool
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !model.searchText.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .needsPairing, .awaitingCode:
                pairingCard
            default:
                searchField
                // Results overlay the remote (same footprint), so the panel never changes size.
                VStack(alignment: .leading, spacing: 16) {
                    nowPlaying
                    volumeRow
                    controls
                    appGrid
                }
                .opacity(isSearching ? 0 : 1)
                .allowsHitTesting(!isSearching)
                .overlay { if isSearching { resultsList } }
            }
            if showSettings { settingsRow }
            footer
        }
        .padding(20)
        .frame(width: 360)
        .background(Palette.panel)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear {
            model.ensureConnected()
            focused = true
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tv")
                .foregroundStyle(Palette.secondary)
            Text(model.deviceName)
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button { model.press(.power) } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Palette.tile))
                    .overlay(Circle().stroke(Palette.accent.opacity(0.5), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
            .help("Power")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
            TextField("Search movies & shows", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onKeyPress(.escape) {
                    model.searchText = ""
                    searchFocused = false
                    focused = true
                    return .handled
                }
            if model.searching {
                ProgressView().controlSize(.small)
            } else if isSearching {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(searchFocused ? Palette.accent.opacity(0.6) : Color.white.opacity(0.05)))
    }

    private var resultsList: some View {
        // Snapshots render the rows without a ScrollView (ImageRenderer can't draw one).
        Group {
            if Snapshot.active {
                resultRows.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView { resultRows }.scrollIndicators(.never)
            }
        }
        .background(Palette.panel)
    }

    private var resultRows: some View {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error = model.searchError {
                    Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                } else if !model.searching && model.results.isEmpty && model.searchText.count >= 2 {
                    Text("No matches").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                }
                ForEach(model.results) { title in
                    resultRow(title)
                }
            }
    }

    private func resultRow(_ title: JustWatch.Title) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: title.poster) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Palette.tileHi
            }
            .frame(width: 46, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(title.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Text([title.year.map(String.init), title.isShow ? "Show" : "Movie"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                if title.offers.isEmpty {
                    Text("Not on your apps")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary.opacity(0.7))
                } else {
                    HStack(spacing: 6) {
                        ForEach(title.offers.prefix(3)) { offer in
                            Button {
                                model.open(offer, title: title.name)
                                // Back to the remote so a profile picker is one OK away.
                                model.searchText = ""
                                searchFocused = false
                                focused = true
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "play.fill").font(.system(size: 8))
                                    Text(offer.app.shortName).font(.system(size: 11, weight: .semibold))
                                    if offer.label != "Stream" {
                                        Text(offer.label).font(.system(size: 10))
                                            .foregroundStyle(Palette.secondary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Capsule().fill(Palette.accent.opacity(0.18)))
                                .overlay(Capsule().stroke(Palette.accent.opacity(0.45)))
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.isConnected)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
    }

    private var nowPlaying: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW ON")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.secondary)
                Text(model.currentAppName)
                    .font(.system(size: 34, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            Button { model.press(.mute) } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Text(model.muted ? "Muted" : "Mute")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(model.muted ? Palette.accent.opacity(0.25) : Palette.tile))
                .overlay(Capsule().stroke(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }

    private var volumeRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                roundButton("minus") { model.press(.volumeDown) }
                VolumeSlider(value: model.volume, max: model.volumeMax) { model.setVolume($0) }
                roundButton("plus") { model.press(.volumeUp) }
            }
            HStack {
                Text("Volume").foregroundStyle(Palette.secondary)
                Spacer()
                Text("\(model.volume)").monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 48)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            DPad(model: model)
            VStack(spacing: 10) {
                tileButton("arrow.uturn.backward", "Back") { model.press(.back) }
                tileButton("house", "Home") { model.press(.home) }
                tileButton("playpause", "Play") { model.press(.playPause) }
            }
        }
    }

    private var appGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(streamingApps) { app in
                let active = app.id == model.currentPackage
                Button { model.open(app) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: app.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(active ? Palette.accent : .white.opacity(0.85))
                        Text(app.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(active ? Palette.tileHi : Palette.tile))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(active ? Palette.accent.opacity(0.6) : Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .disabled(!model.isConnected)
            }
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.phase == .awaitingCode ? "Enter the code shown on the TV" : "This Mac isn't paired with the TV yet.")
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondary)
            if model.phase == .awaitingCode {
                HStack {
                    TextField("A1B2C3", text: $code)
                        .textFieldStyle(.plain)
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.tile))
                        .onSubmit(submitCode)
                    Button("Pair", action: submitCode)
                        .disabled(code.count != 6)
                }
                Button("Cancel") { model.cancelPairing() }
                    .buttonStyle(.link)
            } else {
                Button("Pair with TV") { model.startPairing() }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accentDeep)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.tile))
    }

    private var settingsRow: some View {
        HStack {
            Text("TV IP").foregroundStyle(Palette.secondary)
            TextField("192.168.1.128", text: $model.host)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.connect() }
            Button("Connect") { model.connect() }
        }
        .font(.system(size: 12))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .connected where model.pendingRelaunch != nil:
                Text("Picked a \(model.pendingRelaunch?.appName ?? "") profile?").lineLimit(1)
                Button("Open title again") { model.relaunchPending() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .font(.system(size: 11, weight: .semibold))
            case .connected where model.toast != nil:
                Image(systemName: "play.tv").foregroundStyle(Palette.accent)
                Text(model.toast ?? "").lineLimit(1)
            case .connected:
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("Connected · \(model.host)")
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case .offline(let reason):
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("Offline — retrying").help(reason)
            case .needsPairing, .awaitingCode:
                Text("Not paired")
            }
            Spacer()
            Menu {
                Button("Reconnect") { model.connect() }
                Button(showSettings ? "Hide TV address" : "Change TV address…") { showSettings.toggle() }
                Divider()
                Button("Forget pairing") {
                    ClientIdentity.reset()
                    model.connect()
                }
                Divider()
                Button("Quit TV Remote") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondary)
    }

    // MARK: - Pieces

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.tile))
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
    }

    private func tileButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
    }

    private func submitCode() {
        guard code.count == 6 else { return }
        model.submit(code: code)
        code = ""
    }

    /// Arrow keys = D-pad, Return = OK, Esc/Delete = Back, Space = play/pause, H = Home,
    /// "/" or ⌘F = search. Ignored while typing in the search field.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard model.isConnected, !searchFocused else { return .ignored }
        if press.key == KeyEquivalent("/") || (press.key == KeyEquivalent("f") && press.modifiers.contains(.command)) {
            searchFocused = true
            return .handled
        }
        let map: [KeyEquivalent: KeyCode] = [
            .upArrow: .dpadUp, .downArrow: .dpadDown, .leftArrow: .dpadLeft, .rightArrow: .dpadRight,
            .return: .dpadCenter, .escape: .back, .delete: .back, .space: .playPause,
            KeyEquivalent("h"): .home,
        ]
        guard let key = map[press.key] else { return .ignored }
        model.press(key)
        return .handled
    }
}

private struct DPad: View {
    @ObservedObject var model: BarModel

    var body: some View {
        ZStack {
            Circle().fill(Palette.tile)
            Circle().stroke(Color.white.opacity(0.05))
            arrow("chevron.up", .dpadUp).offset(y: -52)
            arrow("chevron.down", .dpadDown).offset(y: 52)
            arrow("chevron.left", .dpadLeft).offset(x: -52)
            arrow("chevron.right", .dpadRight).offset(x: 52)
            Button { model.press(.dpadCenter) } label: {
                Text("OK")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Palette.panel)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(
                        LinearGradient(colors: [Palette.accent, Palette.accentDeep],
                                       startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
        }
        .frame(width: 150, height: 150)
        .disabled(!model.isConnected)
    }

    private func arrow(_ symbol: String, _ key: KeyCode) -> some View {
        Button { model.press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Capsule slider in the AC-widget style. Drags preview locally and commit on release
/// (the TV only takes volume steps, so we send the difference as key presses).
private struct VolumeSlider: View {
    let value: Int
    let max: Int
    let onCommit: (Int) -> Void
    @State private var dragValue: Int?

    var body: some View {
        GeometryReader { geo in
            let shown = Double(dragValue ?? value) / Double(Swift.max(max, 1))
            let knob: CGFloat = 26
            let x = (geo.size.width - knob) * shown
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.tile)
                Capsule()
                    .fill(LinearGradient(colors: [Palette.accentDeep.opacity(0.6), Palette.accent.opacity(0.85)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + knob)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: knob, height: 30)
                    .offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let f = Swift.min(Swift.max((g.location.x - knob / 2) / (geo.size.width - knob), 0), 1)
                    dragValue = Int((f * Double(max)).rounded())
                }
                .onEnded { _ in
                    if let v = dragValue { onCommit(v) }
                    dragValue = nil
                })
        }
        .frame(height: 38)
    }
}
