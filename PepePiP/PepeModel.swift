// The hub: settings, brain connection, director, scene, cards; everything the UI and the PiP buttons talk to.
import Foundation
import Combine
import UIKit

enum BuildInfo { static let tag = "0.7 embedded-backdrops" }

enum Background: String, CaseIterable, Identifiable {
    case lounge, office, neon, plain
    var id: String { rawValue }
    var label: String {
        switch self { case .lounge: return "lounge (warm room, spot + rim)"; case .office: return "office (window, desk)"; case .neon: return "neon (drifting glow)"; case .plain: return "plain" }
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

struct Card: Identifiable, Equatable {
    let id = UUID()
    let kind: String   // say | ask | result | tool | status
    let text: String
}

final class PepeModel: ObservableObject {
    static let shared = PepeModel()

    // settings (UserDefaults-backed)
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "host") } }
    @Published var port: Int { didSet { UserDefaults.standard.set(port, forKey: "port") } }
    @Published var pipMode: PiPMode { didSet { UserDefaults.standard.set(pipMode.rawValue, forKey: "pipMode") } }
    @Published var autoPiP: Bool { didSet { UserDefaults.standard.set(autoPiP, forKey: "autoPiP") } }
    @Published var liveActivity: Bool { didSet { UserDefaults.standard.set(liveActivity, forKey: "liveActivity") } }
    @Published var cardSize: CardSize { didSet { UserDefaults.standard.set(cardSize.rawValue, forKey: "cardSize") } }
    @Published var brightness: Double { didSet { UserDefaults.standard.set(brightness, forKey: "brightness"); scene.setBrightness(brightness) } }
    @Published var cigarOn: Bool { didSet { UserDefaults.standard.set(cigarOn, forKey: "cigarOn"); scene.setCigar(on: cigarOn) } }
    @Published var pepeScale: Double { didSet { UserDefaults.standard.set(pepeScale, forKey: "pepeScale"); scene.setFraming(scale: Float(pepeScale)) } }
    @Published var background: Background { didSet { UserDefaults.standard.set(background.rawValue, forKey: "background"); scene.setBackground(background) } }

    /// shown in Settings so builds can be told apart (bump BuildInfo.tag with every change you want to recognise)
    static let versionLine: String = {
        let d = AppResources.ownBundle.infoDictionary ?? [:]
        return "PepePiP \(d["CFBundleShortVersionString"] ?? "?") (\(d["CFBundleVersion"] ?? "?")) · \(BuildInfo.tag)"
    }()

    // live state
    @Published var connected = false
    @Published var status = "starting"
    @Published var bubble: String? = nil
    @Published var pipActive = false
    @Published var sceneLoaded = false
    @Published var cards: [Card] = []
    @Published var cardIndex = 0
    @Published var brainBusy = false
    @Published var synced = false        // the brain drives idle life / smoke / music with timestamped beats
    @Published var logTick = 0

    let scene = PepeScene()
    private(set) var director: Director!
    private var client: BrainClient?
    private var bubbleTimer: Timer?

    private init() {
        let d = UserDefaults.standard
        host = d.string(forKey: "host") ?? "100.64.0.1"          // placeholder: your Linux box's Tailscale IP
        port = d.integer(forKey: "port") == 0 ? 8777 : d.integer(forKey: "port")
        pipMode = PiPMode(rawValue: d.string(forKey: "pipMode") ?? "") ?? .auto
        autoPiP = d.object(forKey: "autoPiP") as? Bool ?? true
        liveActivity = d.object(forKey: "liveActivity") as? Bool ?? false
        cardSize = CardSize(rawValue: d.string(forKey: "cardSize") ?? "") ?? .threeFour
        brightness = d.object(forKey: "brightness") as? Double ?? 1.4
        cigarOn = d.object(forKey: "cigarOn") as? Bool ?? true
        background = Background(rawValue: d.string(forKey: "background") ?? "") ?? .lounge
        pepeScale = d.object(forKey: "pepeScale") as? Double ?? 1.0
        director = Director(model: self)
        Log.add(PepeModel.versionLine)
        Log.onChange = { [weak self] in self?.logTick += 1 }
        scene.load { [weak self] error in
            guard let self else { return }
            if let error { Log.add("glb load failed: \(error)"); self.status = "model failed: \(error.localizedDescription)" }
            else {
                self.scene.setBackground(self.background); self.scene.setBrightness(self.brightness); self.scene.setCigar(on: self.cigarOn); self.scene.setFraming(scale: Float(self.pepeScale))
                self.sceneLoaded = true; self.director.handle(["type": "state", "state": "idle"])
                // first-time users see the smoke once, 8 s after launch
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.cigarOn else { return }
                    Log.add("launch exhale"); self.director.smokeNow()
                }
            }
        }
        connect()
    }

    // MARK: brain
    func connect() {
        client?.close()
        guard let url = URL(string: "ws://\(host):\(port)") else { status = "bad host"; return }
        let c = BrainClient(url: url)
        c.onConnection = { [weak self] up in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connected = up
                if !up { self.synced = false }
                self.director.handle(["type": up ? "brain_up" : "brain_down"])
            }
        }
        c.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.director.handle(ev) } }
        client = c; c.connect()
        status = "connecting to \(host):\(port)"
    }

    /// Brain time (unix seconds) on the phone's clock; equals Date() when no hello carried a clock.
    func brainNow() -> TimeInterval { client?.brainNow() ?? Date().timeIntervalSince1970 }

    func send(chat text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        client?.send(["type": "chat", "text": t])
        director.handle(["type": "user_chat", "text": t, "local": true])
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
        LiveActivityManager.shared.update(state: director.currentState, line: s, enabled: liveActivity)
    }
}
