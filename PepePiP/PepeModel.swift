// The hub: settings, brain connection, director, scene, cards; everything the UI and the PiP buttons talk to.
import Foundation
import Combine
import UIKit

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

    // live state
    @Published var connected = false
    @Published var status = "starting"
    @Published var bubble: String? = nil
    @Published var pipActive = false
    @Published var sceneLoaded = false
    @Published var cards: [Card] = []
    @Published var cardIndex = 0
    @Published var brainBusy = false
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
        director = Director(model: self)
        Log.onChange = { [weak self] in self?.logTick += 1 }
        scene.load { [weak self] error in
            guard let self else { return }
            if let error { Log.add("glb load failed: \(error)"); self.status = "model failed: \(error.localizedDescription)" }
            else { self.sceneLoaded = true; self.director.handle(["type": "state", "state": "idle"]) }
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
                self.director.handle(["type": up ? "brain_up" : "brain_down"])
            }
        }
        c.onEvent = { [weak self] ev in DispatchQueue.main.async { self?.director.handle(ev) } }
        client = c; c.connect()
        status = "connecting to \(host):\(port)"
    }

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
