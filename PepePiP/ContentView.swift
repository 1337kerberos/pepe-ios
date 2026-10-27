// SwiftUI shell: the Pepe view (3:4), status line, chat box, PiP/summary buttons, settings sheet with the log.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: PepeModel
    @State private var chat = ""
    @State private var showSettings = false
    @State private var pipRequest = 0

    var body: some View {
        VStack(spacing: 10) {
            PepeHostView(startRequest: $pipRequest)
                .aspectRatio(3 / 4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        Circle().fill(model.connected ? .green : .red).frame(width: 9, height: 9)
                        Text(model.connected ? "brain" : "offline").font(.caption).foregroundStyle(.white.opacity(0.8))
                        if model.pipActive { Text("PiP").font(.caption.bold()).padding(.horizontal, 6).background(.blue, in: Capsule()).foregroundStyle(.white) }
                    }.padding(10)
                }
            Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            if let b = model.bubble { Text(b).font(.body).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12)).lineLimit(4) }
            HStack {
                TextField("say something to Pepe", text: $chat).textFieldStyle(.roundedBorder).submitLabel(.send)
                    .onSubmit { model.send(chat: chat); chat = "" }
                Button("Send") { model.send(chat: chat); chat = "" }.disabled(chat.isEmpty)
            }
            HStack(spacing: 12) {
                Button { pipRequest += 1 } label: { Label("Float", systemImage: "pip.enter") }.buttonStyle(.borderedProminent).disabled(!model.sceneLoaded)
                Button { model.requestSummary() } label: { Label("Summary", systemImage: "text.bubble") }.buttonStyle(.bordered)
                Button { model.stepCard(-1) } label: { Image(systemName: "backward.fill") }.buttonStyle(.bordered).disabled(model.cards.isEmpty)
                Button { model.stepCard(1) } label: { Image(systemName: "forward.fill") }.buttonStyle(.bordered).disabled(model.cards.isEmpty)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            Text("Tap Float (or swipe home with auto-PiP on): Pepe keeps going in a corner card over any app.")
                .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding()
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: PepeModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "8777"
    @State private var adding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.profiles) { p in
                        HStack {
                            VStack(alignment: .leading) { Text(p.name).font(.body); Text(p.url).font(.footnote.monospaced()).foregroundStyle(.secondary) }
                            Spacer()
                            if p.id == model.selectedProfileId { Image(systemName: "checkmark").foregroundStyle(.blue) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if model.selectedProfileId == p.id { model.connect() } else { model.selectedProfileId = p.id } }
                        .deleteDisabled(p.builtIn)
                    }
                    .onDelete { model.deleteProfiles(at: $0) }
                    if adding {
                        TextField("name", text: $newName)
                        TextField("host (192.168.x.y)", text: $newHost).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                        TextField("port", text: $newPort).keyboardType(.numberPad)
                        HStack {
                            Button("Add") { model.addProfile(name: newName, host: newHost, port: Int(newPort) ?? PepeModel.defaultPort); adding = false; newName = ""; newHost = "" }.disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") { adding = false }
                        }
                    } else {
                        Button { adding = true } label: { Label("Add profile", systemImage: "plus") }
                    }
                    Toggle("Use discovered brain (Bonjour _pepe._tcp)", isOn: $model.useDiscovered)
                    Text(model.discovered.map { "discovered: \($0.host):\($0.port)" } ?? "no brain discovered on this network yet").font(.footnote).foregroundStyle(.secondary)
                    Text("dialing \(model.effectiveHost.host):\(model.effectiveHost.port) (\(model.effectiveHost.source))").font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Brain") } footer: { Text("Tap a profile to select it (tap again to reconnect); swipe to delete your own. Built-ins stay. A discovered brain overrides the selection while the toggle is on.") }
                Section("Picture in Picture") {
                    Picker("Path", selection: $model.pipMode) { ForEach(PiPMode.allCases) { Text($0.label).tag($0) } }
                    Picker("Card", selection: $model.cardSize) { ForEach(CardSize.allCases) { Text($0.label).tag($0) } }
                    Text("iOS picks the card's on-screen size from its aspect; pinch the card to toggle between the two system sizes.").font(.footnote).foregroundStyle(.secondary)
                    Toggle("Start PiP automatically when leaving the app", isOn: $model.autoPiP)
                    Toggle("Live Activity (Lock Screen + Dynamic Island)", isOn: $model.liveActivity)
                }
                Section("Look") {
                    Picker("Background", selection: $model.background) { ForEach(Background.allCases) { Text($0.label).tag($0) } }
                    if model.background == .street { Picker("Street time", selection: $model.streetTime) { ForEach(StreetTime.allCases) { Text($0.label).tag($0) } } }
                    HStack { Text("Brightness"); Slider(value: $model.brightness, in: 0.5...2.0, step: 0.05); Text(String(format: "%.2f", model.brightness)).monospacedDigit().frame(width: 44) }
                    HStack { Text("Pepe scale"); Slider(value: $model.pepeScale, in: 0.6...1.2, step: 0.05); Text(String(format: "%.2f", model.pepeScale)).monospacedDigit().frame(width: 44) }
                    Toggle("Cigar (idle smoke every 45-120 s)", isOn: $model.cigarOn)
                    Toggle("Show co-workers (\(model.agents.count) agent\(model.agents.count == 1 ? "" : "s") reported)", isOn: $model.showWorkers)
                    Button("Exhale now") { model.director.smokeNow() }.disabled(!model.sceneLoaded)
                }
                Section {
                    Toggle("Reactions", isOn: $model.reactionsOn)
                    HStack {
                        Button("Squash") { model.scene.squash(); model.director.react(.veryHappy) }.buttonStyle(.bordered)
                        Button("Stumble") { model.scene.squash(amount: 0.1); model.director.react(.angry, hold: 1) }.buttonStyle(.bordered)
                        Button("Sleep") { model.director.setSleeping(true) }.buttonStyle(.bordered)
                        Button("Wake") { model.director.setSleeping(false) }.buttonStyle(.bordered)
                    }.disabled(!model.sceneLoaded).font(.caption)
                } header: { Text("Reactions") } footer: { Text("Pinch/double-tap the card (sample-buffer path): squash + surprise. Shake: stumble. Face down 2 s: he sleeps, lights dim; pick up: wave. Battery < 20 % or Low Power Mode: bored + \"low battery\"; plug in: very happy. Headphones in: nod. The buttons fake the triggers.") }
                Section("Build") { Text(PepeModel.versionLine).font(.footnote.monospaced()) }
                Section("Log") {
                    ScrollView { Text(Log.lines.suffix(80).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 260).id(model.logTick)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
