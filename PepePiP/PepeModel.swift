// The hub: settings, brain connection, director, scene, cards; everything the UI and the PiP buttons talk to.
import Foundation
import Combine
import UIKit

enum BuildInfo { static let tag = "0.16 approvals from the Lock Screen" }

enum Background: String, CaseIterable, Identifiable {
    case ops, street, nebula, lounge, office, neon, plain
    var id: String { rawValue }
    var label: String {
        switch self { case .ops: return "ops center (office, co-workers)"; case .street: return "street (walks when idle, time of day)"; case .nebula: return "nebula (looping space video, purple rim)"; case .lounge: return "lounge (warm room, spot + rim)"; case .office: return "office (window, desk)"; case .neon: return "neon (drifting glow)"; case .plain: return "plain" }
    }
}

/// PiP card aspect: sets the sample-buffer frame size and the video-call preferredContentSize (iOS picks the on-screen
/// size from the aspect; the user pinches the card between the two system sizes).
enum CardSize: String, CaseIterable, Identifiable {
    case threeFour, nineSixteen, square, tallSmall
    var id: String { rawValue }
    var pixels: CGSize {
        switch self { case .threeFour: return CGSize(width: 540, height: 720); case .nineSixteen: return CGSize(width: 540, height: 960); case .square: return CGSize(width: 540, height: 540); case .tallSmall: return CGSize(width: 270, height: 600) }
    }
    var label: String {
        switch self { case .threeFour: return "3:4 (540x720)"; case .nineSixteen: return "9:16 portrait, narrower card (540x960)"; case .square: return "1:1 (540x540)"; case .tallSmall: return "9:20 tiny feed (270x600), experiment: does iOS give a smaller card?" }
    }
}

struct BrainProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var builtIn: Bool
    var url: String { "ws://\(host):\(port)" }
    static let builtIns = [BrainProfile(id: "wifi", name: "Wi-Fi", host: "192.168.110.204", port: 8777, builtIn: true),
                           BrainProfile(id: "tailscale", name: "Tailscale", host: "100.69.18.56", port: 8777, builtIn: true)]
}

struct Card: Identifiable, Equatable {
    let id = UUID()
    let kind: String   // say | ask | result | tool | status
    let text: String
}

final class PepeModel: ObservableObject {
    static let shared = PepeModel()

    // settings (UserDefaults-backed)
    /// Brain profiles: two built-ins (always present) + user-added ones, persisted as JSON; the selection is persisted too.
    @Published var profiles: [BrainProfile] { didSet { saveProfiles() } }
    @Published var selectedProfileId: String { didSet { UserDefaults.standard.set(selectedProfileId, forKey: "selectedProfile"); connect() } }
    var selectedProfile: BrainProfile { profiles.first { $0.id == selectedProfileId } ?? BrainProfile.builtIns[0] }
    var host: String { selectedProfile.host }
    var port: Int { selectedProfile.port }
    @Published var pipMode: PiPMode { didSet { UserDefaults.standard.set(pipMode.rawValue, forKey: "pipMode") } }
    @Published var autoPiP: Bool { didSet { UserDefaults.standard.set(autoPiP, forKey: "autoPiP") } }
    @Published var liveActivity: Bool { didSet { UserDefaults.standard.set(liveActivity, forKey: "liveActivity"); if liveActivity { LiveActivityManager.shared.start(liveActivityContent(), reason: "toggle on") } else { refreshLiveActivity(force: true) } } }
    @Published var useDiscovered: Bool { didSet { UserDefaults.standard.set(useDiscovered, forKey: "useDiscovered"); connect() } }
    @Published var discovered: (host: String, port: Int)? = nil
    static let defaultPort = 8777
    private let discovery = BrainDiscovery()
    @Published var cardSize: CardSize { didSet { UserDefaults.standard.set(cardSize.rawValue, forKey: "cardSize") } }
    @Published var brightness: Double { didSet { UserDefaults.standard.set(brightness, forKey: "brightness"); scene.setBrightness(brightness) } }
    @Published var cigarOn: Bool { didSet { UserDefaults.standard.set(cigarOn, forKey: "cigarOn"); scene.setCigar(on: cigarOn) } }
    @Published var pepeScale: Double { didSet { UserDefaults.standard.set(pepeScale, forKey: "pepeScale"); scene.setFraming(scale: Float(pepeScale)) } }
    @Published var background: Background { didSet { UserDefaults.standard.set(background.rawValue, forKey: "background"); scene.setBackground(background); director?.backgroundChanged() } }
    /// 0.11: device reactions (card resize, shake, face-down, battery, headphones), Reactions.swift
    @Published var reactionsOn: Bool { didSet { UserDefaults.standard.set(reactionsOn, forKey: "reactions"); if sceneLoaded { reactions.setEnabled(reactionsOn) } } }
    /// 0.12 voice (Voice.swift): spoken replies, push-to-talk mic (audio session playAndRecord), recognition language
    @Published var speakReplies: Bool { didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies"); if !speakReplies { voice.stopSpeaking() } } }
    @Published var micOn: Bool { didSet { UserDefaults.standard.set(micOn, forKey: "micOn"); AudioKeepAlive.shared.configureSession() } }
    @Published var speechLang: String { didSet { UserDefaults.standard.set(speechLang, forKey: "speechLang") } }
    @Published var listening = false
    /// 0.15: "tap" (tap to start, tap again / 2 s silence to stop; default) or "hold" (press and hold, release to send)
    @Published var talkMode: String { didSet { UserDefaults.standard.set(talkMode, forKey: "talkMode") } }
    /// 0.15: use on-device recognition when the locale supports it (falls back to the server on failure)
    @Published var preferOnDevice: Bool { didSet { UserDefaults.standard.set(preferOnDevice, forKey: "preferOnDevice") } }
    /// 0.13 baked smoke (BakedSmoke.swift): six-way Mantaflow cards instead of particles; brightness; atlas V flip (debug)
    @Published var bakedSmoke: Bool { didSet { UserDefaults.standard.set(bakedSmoke, forKey: "bakedSmoke"); applySmoke() } }
    @Published var smokeBrightness: Double { didSet { UserDefaults.standard.set(smokeBrightness, forKey: "smokeBrightness"); applySmoke() } }
    @Published var smokeFlipV: Bool { didSet { UserDefaults.standard.set(smokeFlipV, forKey: "smokeFlipV"); applySmoke() } }
    @Published var nebulaVideo: NebulaVideo.Mode { didSet { UserDefaults.standard.set(nebulaVideo.rawValue, forKey: "nebulaVideo"); scene.setNebulaMode(nebulaVideo) } }
    func applySmoke() { scene.setBakedSmoke(on: bakedSmoke, brightness: Float(smokeBrightness), flipV: smokeFlipV) }
    @Published var streetTime: StreetTime { didSet { UserDefaults.standard.set(streetTime.rawValue, forKey: "streetTime"); scene.setStreetTime(streetTime) } }
    @Published var showWorkers: Bool { didSet { UserDefaults.standard.set(showWorkers, forKey: "showWorkers"); scene.setWorkers(agents, enabled: showWorkers) } }
    /// Claude Code sessions on the laptop (from hello.agents and {"type":"agents"}); the brain's own session is the main Pepe
    @Published var agents: [AgentInfo] = [] { didSet { if sceneLoaded { scene.setWorkers(agents, enabled: showWorkers) }; refreshLiveActivity() } }
    // mirrored into the Live Activity
    var laState = "idle" { didSet { refreshLiveActivity() } }     // idle | thinking | working | waiting | celebrating | failing | smoking | sleeping
    var lastLine = "" { didSet { refreshLiveActivity() } }
    var lastTool = "" { didSet { refreshLiveActivity() } }
    var lastOk: Bool? = nil { didSet { refreshLiveActivity() } }
    /// 0.16: pending brain asks (oldest first): the app card, the Lock Screen / Island Allow + Deny, the PiP bubble
    @Published var asks: [PepeAsk] = [] { didSet { refreshLiveActivity() } }
    private var askTimer: Timer?
    private var pruneTimer: Timer?

    /// shown in Settings so builds can be told apart (bump BuildInfo.tag with every change you want to recognise)
    static let versionLine: String = {
        let d = AppResources.ownBundle.infoDictionary ?? [:]
        return "PepePiP \(d["CFBundleShortVersionString"] ?? "?") (\(d["CFBundleVersion"] ?? "?")) · \(BuildInfo.tag)"
    }()

    // live state
    @Published var connected = false
    @Published var status = "starting"
    @Published var bubble: String? = nil
    @Published var pipActive = false { didSet { scene.nebula.setPiPVisible(pipActive) } }
    @Published var sceneLoaded = false
    @Published var cards: [Card] = []
    @Published var cardIndex = 0
    @Published var brainBusy = false
    @Published var synced = false        // the brain drives idle life / smoke / music with timestamped beats
    @Published var logTick = 0

    let scene = PepeScene()
    private(set) var director: Director!
    private(set) var reactions: Reactions!
    private(set) var voice: Voice!
    private var client: BrainClient?
    private var bubbleTimer: Timer?

    private init() {
        let d = UserDefaults.standard
        var list = BrainProfile.builtIns
        if let data = d.data(forKey: "profiles"), let user = try? JSONDecoder().decode([BrainProfile].self, from: data) { list += user.filter { !$0.builtIn } }
        profiles = list
        let savedSel = d.string(forKey: "selectedProfile") ?? BrainProfile.builtIns[0].id
        selectedProfileId = list.contains(where: { $0.id == savedSel }) ? savedSel : BrainProfile.builtIns[0].id
        useDiscovered = d.object(forKey: "useDiscovered") as? Bool ?? true
        pipMode = PiPMode(rawValue: d.string(forKey: "pipMode") ?? "") ?? .auto
        autoPiP = d.object(forKey: "autoPiP") as? Bool ?? true
        liveActivity = d.object(forKey: "liveActivity") as? Bool ?? true
        cardSize = CardSize(rawValue: d.string(forKey: "cardSize") ?? "") ?? .threeFour
        brightness = d.object(forKey: "brightness") as? Double ?? 1.4
        cigarOn = d.object(forKey: "cigarOn") as? Bool ?? true
        background = Background(rawValue: d.string(forKey: "background") ?? "") ?? .ops
        streetTime = StreetTime(rawValue: d.string(forKey: "streetTime") ?? "") ?? .auto
        reactionsOn = d.object(forKey: "reactions") as? Bool ?? true
        bakedSmoke = d.object(forKey: "bakedSmoke") != nil ? d.bool(forKey: "bakedSmoke") : true   // bool(forKey:) also parses a "-bakedSmoke 0" launch argument
        smokeBrightness = d.object(forKey: "smokeBrightness") as? Double ?? 1.0
        smokeFlipV = d.object(forKey: "smokeFlipV") as? Bool ?? false
        nebulaVideo = NebulaVideo.Mode(rawValue: d.string(forKey: "nebulaVideo") ?? "") ?? .output   // also the -nebulaVideo launch arg
        speakReplies = d.object(forKey: "speakReplies") as? Bool ?? true
        micOn = d.object(forKey: "micOn") as? Bool ?? true
        speechLang = d.string(forKey: "speechLang") ?? "auto"
        talkMode = d.string(forKey: "talkMode") == "hold" ? "hold" : "tap"
        preferOnDevice = d.object(forKey: "preferOnDevice") != nil ? d.bool(forKey: "preferOnDevice") : true
        showWorkers = d.object(forKey: "showWorkers") as? Bool ?? true
        pepeScale = d.object(forKey: "pepeScale") as? Double ?? 1.0
        _ = TestMode.launch
        director = Director(model: self)
        reactions = Reactions(model: self)
        voice = Voice(model: self)
        Log.add(PepeModel.versionLine)
        Log.onChange = { [weak self] in self?.logTick += 1 }
        scene.setNebulaMode(nebulaVideo)
        scene.load { [weak self] error in
            guard let self else { return }
            if let error { Log.add("glb load failed: \(error)"); self.status = "model failed: \(error.localizedDescription)" }
            else {
                self.applySmoke(); self.scene.setStreetTime(self.streetTime); self.scene.setBackground(self.background); self.scene.setBrightness(self.brightness); self.scene.setCigar(on: self.cigarOn); self.scene.setFraming(scale: Float(self.pepeScale))
                self.sceneLoaded = true; self.director.handle(["type": "state", "state": "idle"])
                self.scene.setWorkers(self.agents, enabled: self.showWorkers)
                if self.reactionsOn { self.reactions.start() }
                self.pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.scene.pruneWorkers() }
                if TestMode.on { TestMode.run(model: self); return }
                // first-time users see the smoke once, 8 s after launch
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.cigarOn else { return }
                    Log.add("launch exhale"); self.director.smokeNow()
                }
            }
        }
        discovery.onFound = { [weak self] h, p in
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = self.discovered?.host != h || self.discovered?.port != p
                self.discovered = (h, p)
                if self.useDiscovered, changed { self.connect() }
            }
        }
        if TestMode.on { status = "test mode (brain offline)"; Log.add("test mode: no brain connection"); return }
        discovery.start()
        connect()
    }

    /// what we actually dial: the Bonjour-discovered brain when allowed and seen, else the selected profile
    var effectiveHost: (host: String, port: Int, source: String) {
        if useDiscovered, let d = discovered { return (d.host, d.port, "discovered") }
        return (host, port, "profile \(selectedProfile.name)")
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles.filter { !$0.builtIn }) { UserDefaults.standard.set(data, forKey: "profiles") }
    }

    func addProfile(name: String, host: String, port: Int) {
        let n = name.trimmingCharacters(in: .whitespaces), h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        let p = BrainProfile(id: UUID().uuidString, name: n.isEmpty ? h : n, host: h, port: port, builtIn: false)
        profiles.append(p); selectedProfileId = p.id
    }

    func deleteProfiles(at offsets: IndexSet) {
        let doomed = offsets.map { profiles[$0] }.filter { !$0.builtIn }
        profiles.removeAll { p in doomed.contains { $0.id == p.id } }
        if doomed.contains(where: { $0.id == selectedProfileId }) { selectedProfileId = BrainProfile.builtIns[0].id }
    }

    // MARK: brain
    func connect() {
        client?.close()
        let e = effectiveHost
        guard let url = URL(string: "ws://\(e.host):\(e.port)") else { status = "bad host"; return }
        let c = BrainClient(url: url)
        c.onConnection = { [weak self] up in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = up
                if !up { self.synced = false }
                if up { self.client?.send(["type": "hello", "body": "ios"]) }      // 0.16: answers are attributed to "ios"
                LiveActivityManager.shared.brainConnected(up)
                self.director.handle(["type": up ? "brain_up" : "brain_down"])
                self.refreshLiveActivity(force: true)
            }
        }
        c.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.director.handle(ev) } }
        client = c; c.connect()
        status = "connecting to \(e.host):\(e.port) (\(e.source))"
        scene.setStatus(status)
        Log.add("connect ws://\(e.host):\(e.port) (\(e.source))")
    }

    /// Brain time (unix seconds) on the phone's clock; equals Date() when no hello carried a clock.
    func brainNow() -> TimeInterval { client?.brainNow() ?? Date().timeIntervalSince1970 }

    func send(chat text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        client?.send(["type": "chat", "text": t])
        director.handle(["type": "user_chat", "text": t, "local": true])
    }

    /// PiP play/pause (0.12): while the brain is idle and connected = tap-to-talk (a second press, or 2 s of silence, stops);
    /// otherwise (busy, offline, mic off) the old summary behaviour.
    func playPausePressed() {
        if listening || (micOn && connected && !brainBusy) { voice.toggle(fromPiP: true) } else { requestSummary() }
    }

    /// PiP play/pause button: ask the agent for a one-liner. While the brain is busy a chat would be swallowed as the
    /// answer to a pending `ask` (pepe_brain.py handle()), so then we only show the local status card.
    func requestSummary() {
        if brainBusy || !connected {
            showCard(Card(kind: "status", text: "still on it: \(status)"))
        } else {
            send(chat: "In one short line: what are you doing right now and what is left?")
        }
    }

    // MARK: cards (the PiP skip buttons page through them)
    func addCard(_ kind: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        cards.append(Card(kind: kind, text: t))
        if cards.count > 40 { cards.removeFirst(cards.count - 40) }
        cardIndex = cards.count - 1
    }

    func stepCard(_ delta: Int) {
        guard !cards.isEmpty else { return }
        cardIndex = max(0, min(cards.count - 1, cardIndex + delta))
        showCard(cards[cardIndex], hold: 6)
    }

    func showCard(_ card: Card, hold: TimeInterval = 5) {
        setBubble("\(card.kind == "ask" ? "? " : "")\(card.text)", hold: hold)
    }

    func setBubble(_ text: String?, hold: TimeInterval) {
        bubble = text
        scene.setBubble(text)
        bubbleTimer?.invalidate()
        guard text != nil else { return }
        bubbleTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            self?.bubble = nil; self?.scene.setBubble(nil)
        }
    }

    func setStatus(_ s: String) {
        status = s
        scene.setStatus(s)
        refreshLiveActivity()
    }

    /// Build the Live Activity content from the mirrored fields and push it (the manager throttles and de-duplicates).
    /// The brain being offline does not end it (0.15): the state says "offline" (or the local smoke break) and the line
    /// carries the local status, so the Lock Screen keeps showing something.
    func refreshLiveActivity(force: Bool = false) {
        guard sceneLoaded || force else { return }
        LiveActivityManager.shared.update(liveActivityContent(), enabled: liveActivity)
    }

    func liveActivityContent() -> PepeActivityAttributes.ContentState {
        let line = String((connected ? (lastLine.isEmpty ? status : lastLine) : "brain offline" + (lastLine.isEmpty ? "" : " · last: \(lastLine)")).prefix(80))
        let working = agents.filter { $0.state == "working" || $0.state == "thinking" }.count
        var ask = asks.first
        ask?.text = String(asks.first?.text.prefix(200) ?? "")
        let state = ask != nil ? "waiting" : connected ? laState : (laState == "smoking" ? "smoking" : "sleeping")
        return PepeActivityAttributes.ContentState(state: state, line: line, tool: String(lastTool.prefix(40)),
                                                   agentsWorking: working, agentsTotal: agents.count, agentStates: agents.prefix(6).map { $0.state },
                                                   ok: lastOk, updatedAt: Date(), ask: ask,
                                                   asksWaiting: asks.count)
    }

    // MARK: 0.16 asks ("approvals from the Lock Screen"; brain protocol: brain/pepe_brain.py docstring, NIGHT_brain.md 15)
    /// {"type":"ask",id,...} (or an entry of hello/snapshot `asks`) -> PepeAsk; nil for a legacy ask without an id
    func parseAsk(_ d: [String: Any]) -> PepeAsk? {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        let offset = brainNow() - Date().timeIntervalSince1970               // brain clock - phone clock
        let ttl = (d["ttl_s"] as? Double) ?? 30
        let expires = (d["expires"] as? Double).map { Date(timeIntervalSince1970: $0 - offset) } ?? Date().addingTimeInterval(ttl)
        return PepeAsk(id: id, text: (d["text"] as? String) ?? "?", kind: (d["kind"] as? String) ?? "tool", origin: (d["origin"] as? String) ?? "brain",
                       tool: (d["tool"] as? String) ?? "", cwd: (d["cwd"] as? String) ?? "", expires: expires)
    }

    func addAsk(_ a: PepeAsk) {
        guard !asks.contains(where: { $0.id == a.id }) else { return }
        asks.append(a)
        Log.add("ask \(a.id) (\(a.source)): \(a.text.prefix(80)) · \(Int(a.expires.timeIntervalSinceNow)) s")
        startAskTimer()
    }

    /// hello / snapshot: the brain's pending list replaces ours (a restarted brain has none)
    func setAsks(_ list: [[String: Any]]) {
        let fresh = list.compactMap(parseAsk)
        let sent = Dictionary(asks.map { ($0.id, $0.sent) }, uniquingKeysWith: { a, _ in a })
        asks = fresh.map { (a: PepeAsk) -> PepeAsk in var t = a; t.sent = sent[a.id] ?? ""; return t }
        if !asks.isEmpty { startAskTimer() }
        Log.add("asks from the brain: \(asks.count) pending")
    }

    /// {"type":"ask_resolved",id,answer,by}: someone answered (this phone, another body, a chat), the ttl ran out, or the
    /// requester went away
    func resolveAsk(_ id: String, answer: String, by: String) {
        guard let a = asks.first(where: { $0.id == id }) else { return }
        asks.removeAll { $0.id == id }
        let what = answer == "allow" ? "allowed" : answer == "deny" ? "denied" : answer == "timeout" ? "no answer" : answer
        lastLine = "\(what)\(by.isEmpty || by == "ttl" ? "" : " (\(by))"): \(a.text.prefix(60))"
        if asks.isEmpty, laState == "waiting" { laState = "idle" }
        Log.add("ask \(id) resolved: \(answer) by \(by)")
    }

    /// Allow / Deny from the app card or a Live Activity button. False when the brain is not connected (nothing sent).
    @discardableResult
    func answerAsk(id: String, answer: String, via: String) -> Bool {
        guard connected, let client else {
            Log.add("ask_answer \(answer) for \(id): brain offline, not sent (\(via))")
            setBubble("can't reach the brain to answer", hold: 4); return false
        }
        client.send(["type": "ask_answer", "id": id, "answer": answer, "body": "ios"])
        if let i = asks.firstIndex(where: { $0.id == id }) { asks[i].sent = answer }
        Log.add("ask_answer \(answer) -> \(id) (\(via))")
        return true
    }

    /// LiveActivityIntent path: the app may have been woken in the background; wait up to 6 s for the socket (like
    /// Where / Summary), send, then give the brain up to 1.5 s to resolve so the Lock Screen updates before iOS
    /// suspends us again.
    func handleAskIntent(id: String, answer: String) async {
        Log.add("intent: ask_answer \(answer) \(id) (connected \(connected))")
        var waited = 0
        while !connected, waited < 12 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
        let sent = await MainActor.run { self.answerAsk(id: id, answer: answer, via: "live activity") }
        guard sent else { return }
        var w = 0
        while w < 6 {
            let open = await MainActor.run { self.asks.contains { $0.id == id } }
            if !open { break }
            try? await Task.sleep(nanoseconds: 250_000_000); w += 1
        }
    }

    /// drop asks whose time ran out (the brain also sends ask_resolved "timeout"; this covers a lost socket)
    private func startAskTimer() {
        guard askTimer == nil else { return }
        askTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let gone = self.asks.filter { $0.expires.timeIntervalSinceNow < -3 }
            for a in gone { self.resolveAsk(a.id, answer: "timeout", by: "") }
            if self.asks.isEmpty { t.invalidate(); self.askTimer = nil }
        }
    }

    /// Lock Screen / Island buttons (LiveActivityIntent, runs in this process; the app may have been launched in the
    /// background for it, so wait briefly for the brain socket before sending).
    func handleIntent(_ action: String) async {
        Log.add("intent: \(action) (connected \(connected))")
        var waited = 0
        while !connected, waited < 12 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 1 }
        await MainActor.run {
            switch action {
            case "where": self.requestWhere()
            default: self.requestSummary()
            }
        }
    }

    /// "Where": which directory / which step; like the summary, local card while the brain is busy or away.
    func requestWhere() {
        if brainBusy || !connected {
            let cwd = agents.first?.cwd ?? ""
            showCard(Card(kind: "status", text: "here: \(status)\(cwd.isEmpty ? "" : " · \(cwd)")"))
        } else {
            send(chat: "In one short line: where are you right now (which directory, which file or step)?")
        }
    }
}
