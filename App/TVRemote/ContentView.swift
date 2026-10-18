import ATVRemoteKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = RemoteModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var customLink = ""

    /// Deep links to try. Forms follow what each TV app's intent filters claim (docs/DEEPLINKS.md).
    private let presets: [(String, String)] = [
        ("Netflix · title 80100172", "https://www.netflix.com/title/80100172?source=30"),
        ("Prime Video · The Family Man", "https://app.primevideo.com/detail?gti=amzn1.dv.gti.f6b66cba-48c8-b5ac-83e8-844e3cce6bf6"),
        ("SonyLIV · Scam 1992", "https://www.sonyliv.com/shows/scam-1992-the-harshad-mehta--1700000292"),
        ("Apple TV · Ted Lasso", "https://tv.apple.com/in/show/ted-lasso/umc.cmc.vtoh0mn0xn7t3c643xqonfzy"),
        ("JioHotstar · Aarya", "https://www.hotstar.com/shows/aarya/1260028094"),
        ("YouTube · video", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                if model.phase == .connected {
                    remoteSection
                    linksSection
                }
                logSection
            }
            .navigationTitle(model.deviceName.isEmpty ? "TV Remote" : model.deviceName)
            .sheet(isPresented: .constant(model.phase == .awaitingCode)) { pairingSheet }
        }
        .onAppear {
            model.startDiscovery()
            model.connect()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active, model.phase == .disconnected { model.connect() }
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                TextField("TV IP address", text: $model.host)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Connect") { model.connect() }
                    .disabled(model.phase == .connecting)
            }
            ForEach(model.discovered) { tv in
                Button { model.select(tv) } label: {
                    Label(tv.name, systemImage: "tv")
                }
            }
            switch model.phase {
            case .connecting:
                ProgressView("Connecting…")
            case .needsPairing:
                Button("Pair with TV") { model.startPairing() }
            case .connected:
                LabeledContent("App", value: model.currentApp)
                LabeledContent("Volume", value: model.volume)
            case .disconnected, .awaitingCode:
                EmptyView()
            }
        } header: {
            Text("TV")
        }
    }

    private var remoteSection: some View {
        Section("Remote") {
            VStack(spacing: 18) {
                key(.dpadUp, "chevron.up")
                HStack(spacing: 18) {
                    key(.dpadLeft, "chevron.left")
                    Button { model.press(.dpadCenter) } label: {
                        Text("OK").font(.title2.bold()).frame(width: 72, height: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    key(.dpadRight, "chevron.right")
                }
                key(.dpadDown, "chevron.down")
                HStack(spacing: 18) {
                    key(.back, "arrow.uturn.backward")
                    key(.home, "house")
                    key(.playPause, "playpause")
                }
                HStack(spacing: 18) {
                    key(.volumeDown, "speaker.minus")
                    key(.mute, "speaker.slash")
                    key(.volumeUp, "speaker.plus")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func key(_ code: KeyCode, _ symbol: String) -> some View {
        Button { model.press(code) } label: {
            Image(systemName: symbol).font(.title2).frame(width: 56, height: 56)
        }
        .buttonStyle(.bordered)
    }

    private var linksSection: some View {
        Section("Deep links") {
            ForEach(presets, id: \.1) { name, link in
                Button(name) { model.open(link) }
            }
            HStack {
                TextField("https://…", text: $customLink)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Open") { model.open(customLink) }
                    .disabled(customLink.isEmpty)
            }
        }
    }

    private var logSection: some View {
        Section {
            ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced())
            }
            Button("Forget pairing", role: .destructive) { model.forgetIdentity() }
        } header: {
            Text("Log")
        }
    }

    private var pairingSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("6-character code", text: $code)
                        .font(.title.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                } footer: {
                    Text("Type the code shown on the TV (0–9, A–F).")
                }
                Button("Pair") {
                    model.submit(code: code)
                    code = ""
                }
                .disabled(code.count != 6)
            }
            .navigationTitle("Pair")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelPairing() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
