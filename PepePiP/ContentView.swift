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
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Brain (ws://host:port, Tailscale IP of the Linux box)") {
                    TextField("100.x.y.z", text: $host).keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                    TextField("8777", text: $port).keyboardType(.numberPad)
                    Button("Reconnect") { model.host = host.trimmingCharacters(in: .whitespaces); model.port = Int(port) ?? 8777; model.connect() }
                }
                Section("Picture in Picture") {
                    Picker("Path", selection: $model.pipMode) { ForEach(PiPMode.allCases) { Text($0.label).tag($0) } }
                    Picker("Card", selection: $model.cardSize) { ForEach(CardSize.allCases) { Text($0.label).tag($0) } }
                    Text("iOS picks the card's on-screen size from its aspect; pinch the card to toggle between the two system sizes.").font(.footnote).foregroundStyle(.secondary)
                    Toggle("Start PiP automatically when leaving the app", isOn: $model.autoPiP)
                    Toggle("Live Activity (Dynamic Island) mirror", isOn: $model.liveActivity)
                }
                Section("Look") {
                    Picker("Background", selection: $model.background) { ForEach(Background.allCases) { Text($0.label).tag($0) } }
                    HStack { Text("Brightness"); Slider(value: $model.brightness, in: 0.5...2.0, step: 0.05); Text(String(format: "%.2f", model.brightness)).monospacedDigit().frame(width: 44) }
                    HStack { Text("Pepe scale"); Slider(value: $model.pepeScale, in: 0.6...1.2, step: 0.05); Text(String(format: "%.2f", model.pepeScale)).monospacedDigit().frame(width: 44) }
                    Toggle("Cigar (idle smoke every 45-120 s)", isOn: $model.cigarOn)
                    Button("Exhale now") { model.director.smokeNow() }.disabled(!model.sceneLoaded)
                }
                Section("Build") { Text(PepeModel.versionLine).font(.footnote.monospaced()) }
                Section("Log") {
                    ScrollView { Text(Log.lines.suffix(80).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 260).id(model.logTick)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .onAppear { host = model.host; port = String(model.port) }
        }
    }
}
