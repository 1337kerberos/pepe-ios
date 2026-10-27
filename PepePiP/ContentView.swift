// SwiftUI shell: the Pepe view (3:4), status line, chat box, PiP/summary buttons, settings sheet with the log.
import SwiftUI
import UIKit

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
                MicButton(ui: model.voice.ui, hold: model.talkMode == "hold", enabled: model.micOn,
                          onTap: { model.voice.toggle(fromPiP: false) },
                          onPress: { model.voice.pressBegan() }, onRelease: { model.voice.pressEnded() })
            }
            MicPanel(ui: model.voice.ui, hold: model.talkMode == "hold", micOn: model.micOn)
            HStack(spacing: 8) {
                Button { pipRequest += 1 } label: { Label("Float", systemImage: "pip.enter").lineLimit(1).fixedSize() }.buttonStyle(.borderedProminent).disabled(!model.sceneLoaded)
                Button { model.requestSummary() } label: { Label("Summary", systemImage: "text.bubble").lineLimit(1).fixedSize() }.buttonStyle(.bordered)
                Button { model.stepCard(-1) } label: { Image(systemName: "backward.fill") }.buttonStyle(.bordered).controlSize(.small).disabled(model.cards.isEmpty)
                Button { model.stepCard(1) } label: { Image(systemName: "forward.fill") }.buttonStyle(.bordered).controlSize(.small).disabled(model.cards.isEmpty)
                Spacer()
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            Text("Tap Float (or swipe home with auto-PiP on): Pepe keeps going in a corner card over any app.")
                .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .padding()
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .onAppear {
            // simulator screenshots: -openSettings main|debug|live (TestMode.swift)
            if TestMode.on, TestMode.value("openSettings") != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + (TestMode.time("settingsAt") ?? 2.5)) { showSettings = true }
            }
        }
    }
}

/// 0.15 mic button: a plain view with its own gestures (a SwiftUI Button only fires on release, so "hold to talk" was
/// impossible with it). Tap mode: tap = start / stop. Hold mode: finger down starts, finger up sends.
struct MicButton: View {
    @ObservedObject var ui: VoiceUI
    let hold: Bool
    let enabled: Bool
    let onTap: () -> Void
    let onPress: () -> Void
    let onRelease: () -> Void
    @State var pressed = false

    var body: some View {
        let live = ui.phase == .listening
        let base = Image(systemName: live ? "mic.fill" : "mic")
            .font(.system(size: 19, weight: .semibold))
            .frame(width: 48, height: 36)
            .foregroundStyle(live ? Color.white : (enabled ? Color.accentColor : Color.gray))
            .background(RoundedRectangle(cornerRadius: 9).fill(live ? Color.red : Color.accentColor.opacity(enabled ? 0.16 : 0.06)))
            .scaleEffect(pressed || live ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: live)
            .contentShape(Rectangle())
            .accessibilityLabel(hold ? "hold to talk" : (live ? "stop and send" : "tap to talk"))
            .accessibilityAddTraits(.isButton)
        if !enabled {
            base.opacity(0.5)
        } else if hold {
            base.gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; onPress() } }
                .onEnded { _ in pressed = false; onRelease() })
        } else {
            base.onTapGesture { onTap() }
        }
    }
}

/// State label + level meter + live partial transcript + the last result/error line, right under the mic.
struct MicPanel: View {
    @ObservedObject var ui: VoiceUI
    let hold: Bool
    let micOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption.bold()).foregroundStyle(ui.phase == .error ? .red : .primary).lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                LevelMeter(level: ui.level, active: ui.phase == .listening).frame(width: 56, height: 8)
                Spacer(minLength: 4)
                if !ui.route.isEmpty { Text(ui.route).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
            }
            if !ui.partial.isEmpty, ui.phase == .listening || ui.phase == .recognizing || ui.phase == .sending {
                Text("\u{201C}\(ui.partial)\u{201D}").font(.callout).italic().lineLimit(3)
            }
            if !ui.line.isEmpty {
                Text(ui.line).font(.caption).foregroundStyle(ui.lineIsError ? .red : .secondary).lineLimit(3)
            }
            if ui.showOpenSettings {
                Button("Open iOS Settings > Pepe") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.font(.caption)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var label: String {
        if !micOn { return "mic off (Settings > Voice)" }
        switch ui.phase {
        case .idle: return hold ? "mic idle: hold the mic to talk" : "mic idle: tap the mic to talk"
        case .listening: return hold ? "listening: release to send" : "listening: tap again to send"
        default: return ui.label
        }
    }
    private var color: Color {
        switch ui.phase {
        case .listening: return .red; case .recognizing, .starting, .asking: return .orange; case .sending, .sent: return .green
        case .error: return .red; case .idle: return micOn ? .gray : .gray.opacity(0.4)
        }
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(level > 0.75 ? Color.orange : Color.green)
                    .frame(width: max(0, g.size.width * CGFloat(active ? level : 0)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: PepeModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newHost = ""
    @State private var newPort = "8777"
    @State private var adding = false
    @State private var path: [String] = {
        let p = TestMode.on ? (TestMode.value("openSettings") ?? "main") : "main"
        return p == "main" ? [] : [p]
    }()

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: "debug") { Label("Debug (screenshot this for us)", systemImage: "stethoscope") }
                    NavigationLink(value: "live") { Label("Live Activity test", systemImage: "platter.filled.top.iphone") }
                } header: { Text("Diagnostics") } footer: { Text(PepeModel.versionLine + " · " + InstallInfo.kind) }
                LiveActivityPanel()
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
                    if model.background == .nebula { Picker("Nebula video", selection: $model.nebulaVideo) { ForEach(NebulaVideo.Mode.allCases) { Text($0.label).tag($0) } } }
                    HStack { Text("Brightness"); Slider(value: $model.brightness, in: 0.5...2.0, step: 0.05); Text(String(format: "%.2f", model.brightness)).monospacedDigit().frame(width: 44) }
                    HStack { Text("Pepe scale"); Slider(value: $model.pepeScale, in: 0.6...1.2, step: 0.05); Text(String(format: "%.2f", model.pepeScale)).monospacedDigit().frame(width: 44) }
                    Toggle("Cigar (idle smoke every 45-120 s)", isOn: $model.cigarOn)
                    Toggle("Show co-workers (\(model.agents.count) agent\(model.agents.count == 1 ? "" : "s") reported)", isOn: $model.showWorkers)
                    Toggle("Baked smoke (Mantaflow cards; off = particles)", isOn: $model.bakedSmoke)
                    HStack { Text("Smoke light"); Slider(value: $model.smokeBrightness, in: 0.3...2.5, step: 0.05); Text(String(format: "%.2f", model.smokeBrightness)).monospacedDigit().frame(width: 44) }
                    Toggle("Smoke atlas: flip V (if the exhale plays upside down)", isOn: $model.smokeFlipV)
                    Button("Exhale now") { model.director.smokeNow() }.disabled(!model.sceneLoaded)
                }
                Section {
                    Toggle("Speak replies", isOn: $model.speakReplies)
                    Toggle("Microphone", isOn: $model.micOn)
                    Picker("Talk mode", selection: $model.talkMode) { Text("Tap to talk").tag("tap"); Text("Hold to talk").tag("hold") }.pickerStyle(.segmented)
                    Picker("Speech language", selection: $model.speechLang) { ForEach(VoiceIO.languages, id: \.id) { Text($0.label).tag($0.id) } }
                    Toggle("Prefer on-device recognition", isOn: $model.preferOnDevice)
                    Text("mic \(Voice.micStatus) · speech \(Voice.speechStatus) · \(model.voice.recognizerSummary)").font(.footnote.monospaced()).foregroundStyle(.secondary)
                    Button("Open iOS Settings > Pepe (permissions)") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.font(.footnote)
                } header: { Text("Voice") } footer: { Text("Tap to talk: tap the mic, speak, then tap again or just stop talking for 2 s; the words show under the button while you speak. Hold to talk: press and hold, release to send. The PiP play/pause button (while Pepe is idle) works like tap to talk. On-device recognition is used when the language supports it; if it fails the same audio goes to Apple's server recognizer. Replies are spoken with the best installed voice for their language. Microphone off = the old playback-only audio session, if PiP misbehaves.") }
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
            .navigationDestination(for: String.self) { page in
                switch page {
                case "live": Form { LiveActivityPanel() }.navigationTitle("Live Activity")
                default: DiagnosticsView(voiceUI: model.voice.ui)
                }
            }
        }
    }
}
