import ATVRemoteKit
import SwiftUI

// Same look as the Mac menu-bar widget (Sources/TVRemoteBar/PanelView.swift): near-black panel,
// graphite tiles, warm beige accent.
enum Palette {
    static let panel = Color(red: 0.055, green: 0.055, blue: 0.06)
    static let tile = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let tileHi = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let accent = Color(red: 0.85, green: 0.80, blue: 0.71)
    static let accentDeep = Color(red: 0.52, green: 0.48, blue: 0.41)
    static let secondary = Color.white.opacity(0.55)
}

struct ContentView: View {
    @ObservedObject private var model = RemoteModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var showSettings = false
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !model.searchText.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch model.phase {
            case .needsPairing, .awaitingCode:
                pairingCard
                Spacer(minLength: 0)
            default:
                searchField
                // The remote stays mounted under the results so typing never swaps the view tree
                // (which would drop the search field's focus mid-word).
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        nowPlaying
                        volumeRow
                        controls
                        appGrid
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .opacity(isSearching ? 0 : 1)
                .allowsHitTesting(!isSearching)
                .overlay { if isSearching { resultsList } }
            }
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Palette.panel.ignoresSafeArea())
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .onAppear {
            model.startDiscovery()
            model.ensureConnected()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.ensureConnected() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tv").foregroundStyle(Palette.secondary)
            Text(model.deviceName)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer()
            Button { tap(.power) } label: {
                Image(systemName: "power")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Palette.tile))
                    .overlay(Circle().stroke(Palette.accent.opacity(0.5), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
            TextField("Search movies & shows", text: $model.searchText)
                .font(.system(size: 16))
                .focused($searchFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searchFocused = false }
            if model.searching {
                ProgressView().controlSize(.small)
            } else if isSearching || searchFocused {
                Button {
                    model.searchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(searchFocused ? Palette.accent.opacity(0.6) : Color.white.opacity(0.05)))
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let error = model.searchError {
                    Text(error).font(.system(size: 14)).foregroundStyle(.orange)
                } else if !model.searching && model.results.isEmpty && model.searchText.count >= 2 {
                    Text("No matches").font(.system(size: 14)).foregroundStyle(Palette.secondary)
                }
                ForEach(model.results) { title in resultRow(title) }
            }
        }
        .scrollIndicators(.never)
        .scrollDismissesKeyboard(.immediately)
        .background(Palette.panel)
    }

    private func resultRow(_ title: JustWatch.Title) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: title.poster) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Palette.tileHi
            }
            .frame(width: 54, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(title.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text([title.year.map(String.init), title.isShow ? "Show" : "Movie"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                if title.offers.isEmpty {
                    Text("Not on your apps")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary.opacity(0.7))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(title.offers) { offer in chip(offer, title: title.name) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
    }

    private func chip(_ offer: JustWatch.Offer, title: String) -> some View {
        Button {
            model.open(offer, title: title)
            // Back to the remote so a profile picker is one OK away.
            model.searchText = ""
            searchFocused = false
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "play.fill").font(.system(size: 9))
                Text(offer.app.shortName).font(.system(size: 13, weight: .semibold))
                if offer.label != "Stream" {
                    Text(offer.label).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Capsule().fill(Palette.accent.opacity(0.18)))
            .overlay(Capsule().stroke(Palette.accent.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
    }

    private var nowPlaying: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW ON")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.secondary)
                Text(model.currentAppName)
                    .font(.system(size: 36, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer()
            Button { tap(.mute) } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    Text(model.muted ? "Muted" : "Mute").font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(model.muted ? Palette.accent.opacity(0.25) : Palette.tile))
                .overlay(Capsule().stroke(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!model.isConnected)
        }
    }

    private var volumeRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                roundButton("minus") { tap(.volumeDown) }
                VolumeSlider(value: model.volume, max: model.volumeMax) { model.setVolume($0) }
                    .disabled(!model.isConnected)
                roundButton("plus") { tap(.volumeUp) }
            }
            HStack {
                Text("Volume").foregroundStyle(Palette.secondary)
                Spacer()
                Text("\(model.volume)").monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 54)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            DPad(enabled: model.isConnected) { tap($0) }
            VStack(spacing: 12) {
                tileButton("arrow.uturn.backward", "Back") { tap(.back) }
                tileButton("house", "Home") { tap(.home) }
                tileButton("playpause", "Play") { tap(.playPause) }
            }
        }
    }

    private var appGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(streamingApps) { app in
                let active = app.id == model.currentPackage
                Button {
                    haptic()
                    model.open(app)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: app.symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(active ? Palette.accent : .white.opacity(0.85))
                        Text(app.name)
                            .font(.system(size: 13, weight: .medium))
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
            Text(model.phase == .awaitingCode ? "Enter the code shown on the TV"
                                              : "This iPhone isn't paired with the TV yet.")
                .font(.system(size: 14))
                .foregroundStyle(Palette.secondary)
            if model.phase == .awaitingCode {
                HStack {
                    TextField("A1B2C3", text: $code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onSubmit(submitCode)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.tile))
                    Button("Pair", action: submitCode)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Palette.panel)
                        .disabled(code.count != 6)
                }
                Button("Cancel") { model.cancelPairing() }
                    .font(.system(size: 13))
            } else {
                Button { model.startPairing() } label: {
                    Text("Pair with TV")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.panel)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Palette.tile))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            switch model.phase {
            case .connected where model.pendingRelaunch != nil:
                Text("Picked a \(model.pendingRelaunch?.appName ?? "") profile?").lineLimit(1)
                Spacer()
                Button("Open title again") { model.relaunchPending() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accent)
                    .font(.system(size: 13, weight: .semibold))
            case .connected where model.toast != nil:
                Image(systemName: "play.tv").foregroundStyle(Palette.accent)
                Text(model.toast ?? "").lineLimit(1)
            case .connected:
                Circle().fill(Color.green.opacity(0.8)).frame(width: 6, height: 6)
                Text("Connected · \(model.host)")
            case .connecting:
                ProgressView().controlSize(.mini)
                Text("Syncing…")
            case .offline:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("Offline — retrying")
            case .needsPairing, .awaitingCode:
                Text("Not paired")
            }
            if model.pendingRelaunch == nil || model.phase != .connected { Spacer() }
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13))
        .foregroundStyle(Palette.secondary)
        .frame(height: 30)
    }

    // MARK: - Pieces

    private func tap(_ key: KeyCode) {
        haptic()
        model.press(key)
    }

    private func haptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(Circle().fill(Palette.tile))
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
    }

    private func tileButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 14).fill(Palette.tile))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.isConnected)
    }

    private func submitCode() {
        guard code.count == 6 else { return }
        model.submit(code: code)
        code = ""
    }
}

private struct DPad: View {
    let enabled: Bool
    let press: (KeyCode) -> Void

    var body: some View {
        ZStack {
            Circle().fill(Palette.tile)
            Circle().stroke(Color.white.opacity(0.05))
            arrow("chevron.up", .dpadUp).offset(y: -66)
            arrow("chevron.down", .dpadDown).offset(y: 66)
            arrow("chevron.left", .dpadLeft).offset(x: -66)
            arrow("chevron.right", .dpadRight).offset(x: 66)
            Button { press(.dpadCenter) } label: {
                Text("OK")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Palette.panel)
                    .frame(width: 74, height: 74)
                    .background(Circle().fill(
                        LinearGradient(colors: [Palette.accent, Palette.accentDeep],
                                       startPoint: .top, endPoint: .bottom)))
            }
            .buttonStyle(.plain)
        }
        .frame(width: 190, height: 190)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func arrow(_ symbol: String, _ key: KeyCode) -> some View {
        Button { press(key) } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 54, height: 54)
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
            let knob: CGFloat = 28
            let x = (geo.size.width - knob) * shown
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.tile)
                Capsule()
                    .fill(LinearGradient(colors: [Palette.accentDeep.opacity(0.6), Palette.accent.opacity(0.85)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + knob)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: knob, height: 32)
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
        .frame(height: 42)
    }
}

/// TV address, discovery, deep-link testing and the log: what the Mac widget keeps in its menu.
private struct SettingsSheet: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var customLink = ""
    @State private var confirmForget = false

    var body: some View {
        NavigationStack {
            Form {
                Section("TV") {
                    HStack {
                        TextField("TV IP address", text: $model.host)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Connect") { model.connect() }
                    }
                    ForEach(model.discovered) { tv in
                        Button { model.select(tv) } label: { Label(tv.name, systemImage: "tv") }
                    }
                    Button("Reconnect") { model.connect() }
                    Button("Forget pairing", role: .destructive) { confirmForget = true }
                        .confirmationDialog("Forget pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
                            Button("Forget pairing", role: .destructive) { model.forgetIdentity() }
                        } message: {
                            Text("You'll need to pair again with the code the TV shows.")
                        }
                }
                Section("Open a link") {
                    HStack {
                        TextField("https://…", text: $customLink)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Open") { model.open(customLink) }
                            .disabled(customLink.isEmpty || !model.isConnected)
                    }
                }
                Section("Log") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .tint(Palette.accent)
    }
}
