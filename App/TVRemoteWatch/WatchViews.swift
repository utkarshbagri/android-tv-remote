import ATVRemoteKit
import SwiftUI

// Same palette as the iPhone app and the Mac widget.
private enum Palette {
    static let tile = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let tileHi = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let accent = Color(red: 0.85, green: 0.80, blue: 0.71)
    static let accentDeep = Color(red: 0.52, green: 0.48, blue: 0.41)
    static let secondary = Color.white.opacity(0.55)
}

struct WatchRootView: View {
    @ObservedObject var model: WatchModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            NavigationStack { RemotePage(model: model) }.tag(0)
            NavigationStack { AppsPage(model: model) }.tag(1)
            // After opening a result, back to the remote so a profile picker is one OK away.
            NavigationStack { SearchPage(model: model) { page = 0 } }.tag(2)
        }
        .tabViewStyle(.verticalPage)
        .tint(Palette.accent)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refresh() }
        }
    }
}

// MARK: - Remote: D-pad grid, crown = volume

private struct RemotePage: View {
    @ObservedObject var model: WatchModel
    @State private var crown = 0.0
    @State private var lastStep = 0
    @State private var showVolume = false
    @State private var hideVolume: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 4) {
            status
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    key("arrow.uturn.backward", .back)
                    key("chevron.up", .dpadUp)
                    key("house", .home)
                }
                GridRow {
                    key("chevron.left", .dpadLeft)
                    okButton
                    key("chevron.right", .dpadRight)
                }
                GridRow {
                    key("playpause", .playPause)
                    key("chevron.down", .dpadDown)
                    key(model.muted ? "speaker.slash.fill" : "speaker.wave.2", .mute)
                }
            }
        }
        .overlay(alignment: .bottom) { if showVolume { volumeBar } }
        .focusable()
        .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1,
                              sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, value in
            let step = Int(value.rounded())
            let delta = step - lastStep
            guard delta != 0 else { return }
            lastStep = step
            model.nudgeVolume(by: delta)
            flashVolume()
        }
        .navigationTitle(model.nowOn)
    }

    @ViewBuilder private var status: some View {
        if let pending = model.pending {
            Button("Open title again") { model.relaunch() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .buttonStyle(.plain)
                .accessibilityHint("Picked a \(pending) profile? Sends the title link again.")
        } else if let error = model.lastError {
            Text(error).font(.system(size: 12)).foregroundStyle(.orange)
        } else if !model.connected {
            Text("Connecting…").font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
    }

    private var okButton: some View {
        Button { model.press(.dpadCenter) } label: {
            Text("OK")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Circle().fill(LinearGradient(colors: [Palette.accent, Palette.accentDeep],
                                                         startPoint: .top, endPoint: .bottom)))
        }
        .buttonStyle(.plain)
    }

    private func key(_ symbol: String, _ code: KeyCode) -> some View {
        Button { model.press(code) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.tile))
        }
        .buttonStyle(.plain)
    }

    private var volumeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: 11))
            ProgressView(value: Double(model.volume), total: Double(model.volumeMax))
                .tint(Palette.accent)
            Text("\(model.volume)").font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Palette.tileHi))
    }

    private func flashVolume() {
        showVolume = true
        hideVolume?.cancel()
        hideVolume = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { showVolume = false }
        }
    }
}

// MARK: - Apps

private struct AppsPage: View {
    @ObservedObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("NOW ON").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(Palette.secondary)
                Text(model.nowOn).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    .minimumScaleFactor(0.6)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)],
                          spacing: 6) {
                    ForEach(streamingApps) { app in
                        let active = app.id == model.package
                        Button { model.open(app) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Image(systemName: app.symbol)
                                    .foregroundStyle(active ? Palette.accent : .white.opacity(0.85))
                                Text(app.shortName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Palette.tileHi : Palette.tile))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(active ? Palette.accent.opacity(0.6) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Apps")
    }
}

// MARK: - Search (dictate / scribble a title, tap an app to open it on the TV)

private struct SearchPage: View {
    @ObservedObject var model: WatchModel
    let onOpened: () -> Void
    @State private var query = ""

    var body: some View {
        List {
            TextField("Search movies & shows", text: $query)
                .onSubmit { model.search(query) }
            if model.searching {
                ProgressView()
            } else if let error = model.searchError {
                Text(error).font(.footnote).foregroundStyle(.orange)
            } else if model.results.isEmpty && query.count >= 2 {
                Text("No matches").foregroundStyle(Palette.secondary)
            }
            ForEach(model.results.filter { !$0.offers.isEmpty }) { title in
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text([title.year.map(String.init), title.isShow ? "Show" : "Movie"]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                    ForEach(title.offers) { offer in
                        Button {
                            model.open(offer, title: title.name)
                            query = ""
                            model.results = []
                            onOpened()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill").font(.system(size: 9))
                                Text(offer.app.shortName).font(.system(size: 13, weight: .semibold))
                                if offer.label != "Stream" {
                                    Text(offer.label).font(.system(size: 11)).foregroundStyle(Palette.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                            .background(Capsule().fill(Palette.accent.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .navigationTitle("Search")
    }
}
