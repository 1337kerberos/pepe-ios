// Brain events -> the app's small clip set, status line, bubble and cards. A compact port of brain/director_rules.json:
// raw events (state/text/tool/result/ask/point/hello) drive the base loop; `beat` events are used only for one-shot
// reactions whose clip we have (variety from idle_life/progress rotations), never for loops, so the two never fight.
import Foundation
import QuartzCore

enum Clip: String, CaseIterable {
    case idle = "idle_standing_a", shift = "shifting_weight", look = "look_around", breathe = "idle_breathing"
    case think, typing, explain, talkingFunny = "talking_funny", acknowledging, nod = "head_nod_yes"
    case fistPump = "fist_pump", veryHappy = "very_happy", cheering, shakeNo = "shaking_head_no", angry = "standing_angry"
    case wave = "wave_hello", phone = "talking_on_phone", bored
    case smokeLight = "smoke_light", smokeExhale = "smoke_exhale"   // smoke_light has no boss bake yet: absent from the glb until baked

    var loops: Bool {
        switch self {
        case .idle, .shift, .look, .breathe, .think, .typing, .explain, .talkingFunny, .phone, .bored: return true
        default: return false
        }
    }
}

/// retarget_lab/anims names used by director_rules.json -> our clips (fallbacks folded in)
let clipAliases: [String: Clip] = [
    "mx_idle_standing_a": .idle, "mx_idle_weight_shift": .shift, "mx_idle_look_around": .look, "mx_idle_breathing": .breathe,
    "mx_thinking": .think, "mx_typing": .typing, "mx_typing_standing": .typing, "cmu_explain": .explain, "mx_talking": .explain,
    "mx_talking_funny": .talkingFunny, "mx_acknowledging": .acknowledging, "mx_head_nod_yes": .nod, "mx_thumbs_up": .nod,
    "mx_standing_fist_pump": .fistPump, "mx_victory_idle": .veryHappy, "mx_cheering": .cheering, "mx_shaking_head_no": .shakeNo,
    "mx_shrug": .shakeNo, "mx_standing_angry": .angry, "meshy_facepalm": .angry, "cmu_wave_hello": .wave,
    "mx_talking_on_phone": .phone, "mx_bored": .bored, "mx_pointing": .explain, "cmu_stretching": .shift, "mx_look_at_watch": .shift,
    "mx_drinking": .look, "vid_smoke_light": .smokeLight, "vid_smoke_exhale": .smokeExhale,
]

final class Director {
    unowned let model: PepeModel
    private(set) var currentState = "idle"
    private var baseLoop: Clip = .idle
    private var oneShotUntil: TimeInterval = 0
    private var turnHadExec = false
    private var talkFlip = false
    private var idleTimer: Timer?
    private var smokeTimer: Timer?

    init(model: PepeModel) { self.model = model }

    // MARK: entry
    func handle(_ ev: [String: Any]) {
        guard let type = ev["type"] as? String else { return }
        let text = (ev["text"] as? String) ?? ""
        switch type {
        case "hello":
            model.brainBusy = (ev["busy"] as? Bool) ?? false
            oneShot(.wave, hold: 2.2)
            say("hi, ask me anything", hold: 3)
        case "state":
            setState((ev["state"] as? String) ?? "idle")
        case "text":
            let clean = text.replacingOccurrences(of: #"\s*\[\w+\]"#, with: "", options: .regularExpression)
            loop(talkFlip ? .talkingFunny : .explain); talkFlip.toggle()
            say(clean, hold: min(20, 6 + 0.03 * Double(clean.count)))
            model.addCard("say", clean)
        case "tool":
            onTool(ev)
        case "result":
            let ok = (ev["ok"] as? Bool) ?? false
            let summary = (ev["summary"] as? String) ?? ""
            if ok {
                oneShot(turnHadExec ? .fistPump : .nod, hold: turnHadExec ? 3.8 : 1.5)
                model.setStatus("done")
            } else {
                oneShot(.angry, hold: 3) { [weak self] in self?.loop(.bored) }
                say("hm, that went wrong: \(summary)", hold: 8)
                model.setStatus("error")
            }
            model.addCard("result", summary)
            turnHadExec = false
        case "ask":
            loop(.think)
            say("? \(text)", hold: 20)
            model.setStatus("needs you")
            model.addCard("ask", text)
        case "point":
            oneShot(.explain, hold: 3)
            say((ev["label"] as? String) ?? "there", hold: 4)
        case "user_chat":
            if ev["local"] == nil, model.brainBusy { oneShot(.acknowledging, hold: 1) }
            if ev["local"] != nil { model.brainBusy = true; turnHadExec = false; model.setStatus("sent") }
        case "beat":
            onBeat(ev)
        case "brain_down":
            loop(.bored); model.setStatus("brain offline"); model.brainBusy = false
        case "brain_up":
            oneShot(.nod, hold: 1.2); model.setStatus("connected")
        case "interrupt":
            oneShot(.acknowledging, hold: 1); say("ok, stopping", hold: 2)
        default: break
        }
    }

    private func setState(_ s: String) {
        currentState = s
        if s != "idle" { smokeTimer?.invalidate() }
        switch s {
        case "idle":
            model.brainBusy = false; loop(.idle); model.setStatus("idle"); scheduleIdleLife(); scheduleSmoke()
        case "thinking":
            model.brainBusy = true; loop(.think); model.setStatus("thinking")
        case "working":
            model.brainBusy = true; if baseLoop != .typing && baseLoop != .look && baseLoop != .phone { loop(.typing) }
            if model.status == "thinking" { model.setStatus("working") }
        case "talking":
            model.brainBusy = true; model.setStatus("talking")
        case "done":
            model.setStatus("done")
        case "error":
            model.setStatus("error")
        default: break
        }
    }

    private func onTool(_ ev: [String: Any]) {
        let phase = (ev["phase"] as? String) ?? ""
        let name = ((ev["name"] as? String) ?? "?").replacingOccurrences(of: "mcp__desktop__", with: "")
        let summary = String(((ev["summary"] as? String) ?? "").prefix(60))
        switch phase {
        case "start":
            let exec = ["Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "desktop_type", "desktop_click"].contains(name)
            if exec { turnHadExec = true }
            let web = ["WebFetch", "WebSearch", "Agent", "Task"].contains(name)
            loop(web ? .phone : exec ? .typing : .look)
            model.setStatus(web ? "looking it up" : exec ? "\(name) \(summary)" : "reading \(summary.split(separator: "/").last.map(String.init) ?? summary)")
        case "done":
            model.setStatus("\(name) done")
        case "fail":
            oneShot(.shakeNo, hold: 1.8)
            model.setStatus("failed: \(summary)")
            model.addCard("tool", "\(name) failed: \(summary)")
        default: break
        }
    }

    /// Director beats: take one-shot reactions we can play (react/emote/celebrate/use_prop) and their bubbles.
    private func onBeat(_ ev: [String: Any]) {
        guard let beats = ev["beats"] as? [[String: Any]] else { return }
        for b in beats {
            let verb = (b["verb"] as? String) ?? ""
            let raw = ((b["clip"] as? String) ?? "").split(separator: "@").first.map(String.init) ?? ""
            let isLoop = (b["loop"] as? Bool) ?? false
            if let clip = clipAliases[raw], !isLoop, ["react", "emote", "celebrate", "use_prop"].contains(verb), model.scene.has(clip.rawValue) {
                if clip == .smokeLight || clip == .smokeExhale { if model.cigarOn { smokeNow() }; continue }
                let hold = (b["max_hold_s"] as? Double) ?? model.scene.duration(of: clip.rawValue)
                oneShot(clip, hold: hold)
            }
            if let bubble = b["bubble"] as? String, (b["bubble_style"] as? String) == "aside" { say(bubble, hold: 3) }
            if let status = b["status"] as? String, verb == "gaze" { model.setStatus(status) }
        }
    }

    // MARK: playback helpers
    private func loop(_ clip: Clip) {
        baseLoop = clip
        if CACurrentMediaTime() >= oneShotUntil { model.scene.play(clip.rawValue, loop: true) }
    }

    private func oneShot(_ clip: Clip, hold: TimeInterval, then: (() -> Void)? = nil) {
        oneShotUntil = CACurrentMediaTime() + hold
        model.scene.play(clip.rawValue, loop: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, CACurrentMediaTime() >= self.oneShotUntil - 0.05 else { return }
            if let then { then() } else { self.model.scene.play(self.baseLoop.rawValue, loop: true) }
        }
    }

    private func say(_ text: String, hold: TimeInterval) {
        model.setBubble(String(text.prefix(220)), hold: hold)
    }

    /// Smoke break, like the desktop idle_life smoke entry: after 45-120 s of idle (cigar on) play smoke_light if it is
    /// in the glb, then the exhale take (the burst fires at 4.33 s, PepeScene), then back to idle.
    private func scheduleSmoke() {
        smokeTimer?.invalidate()
        smokeTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 45...120), repeats: false) { [weak self] _ in
            guard let self, self.currentState == "idle", self.model.cigarOn else { return }
            self.smokeNow()
            self.scheduleSmoke()
        }
    }

    func smokeNow() {
        guard model.scene.has(Clip.smokeExhale.rawValue) else { Log.add("no smoke take in the glb"); return }
        idleTimer?.invalidate()
        let exhale = { [weak self] in
            guard let self else { return }
            self.oneShot(.smokeExhale, hold: self.model.scene.duration(of: Clip.smokeExhale.rawValue)) { [weak self] in
                guard let self else { return }
                self.model.scene.play(self.baseLoop.rawValue, loop: true)
                if self.currentState == "idle" { self.scheduleIdleLife() }
            }
        }
        if model.scene.has(Clip.smokeLight.rawValue) {
            oneShot(.smokeLight, hold: model.scene.duration(of: Clip.smokeLight.rawValue), then: exhale)
        } else { exhale() }
    }

    /// idle_life: every 8-20 s of idle play a short variation, then return to the base idle.
    private func scheduleIdleLife() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 8...20), repeats: false) { [weak self] _ in
            guard let self, self.currentState == "idle" else { return }
            let pick = [Clip.shift, Clip.look, Clip.breathe].randomElement()!
            self.oneShot(pick, hold: min(8, self.model.scene.duration(of: pick.rawValue)))
            self.scheduleIdleLife()
        }
    }
}
