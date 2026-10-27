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
    case walk = "meshy_walk_normal"                                   // in place (0.10 street treadmill; 0.17: Meshy normal walk, was the cmu "walk")
    case smokeLight = "smoke_light", smokeExhale = "smoke_exhale"   // smoke_light has no boss bake yet: absent from the glb until baked

    var loops: Bool {
        switch self {
        case .idle, .shift, .look, .breathe, .think, .typing, .explain, .talkingFunny, .phone, .bored, .walk: return true
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
    "mx_drinking": .look, "cmu_casual_walk": .walk, "meshy_walk_normal": .walk, "meshy_walk_boss": .walk, "vid_smoke_light": .smokeLight, "vid_smoke_exhale": .smokeExhale,
    // desktop-only clips -> closest on the phone (music / dance / idle-life extras)
    "wows_desk_dance": .cheering, "cmu_mickey_dance": .cheering, "cmu_charleston_side_by_sid": .cheering, "wows_knee_slide": .veryHappy,
    "meshy_make_it_rain": .veryHappy, "idle_hands_pockets": .shift, "meshy_idle_arms_crossed": .idle, "cmu_combing_hair": .look,
    "mx_yawn": .bored, "mx_sitting_idle": .bored, "mx_stand_to_sit": .bored, "mx_sit_to_stand": .acknowledging, "cmu_laugh": .talkingFunny,
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

    /// The idle base loop: on the street preset he walks in place while the set scrolls (StreetSet), else he stands.
    private var idleClip: Clip {
        if sleeping || lowBattery { return .bored }                     // 0.11 reactions: face-down sleep, low battery
        return model.background == .street && model.scene.has(Clip.walk.rawValue) ? .walk : .idle
    }
    private var offline = false
    private var sleeping = false
    private var lowBattery = false

    // MARK: device reactions (Reactions.swift)
    /// a one-shot on top of whatever loop is running, then back to it
    func react(_ clip: Clip, hold: TimeInterval? = nil, bubble: String? = nil) {
        guard model.scene.has(clip.rawValue) else { return }
        oneShot(clip, hold: hold ?? model.scene.duration(of: clip.rawValue))
        if let bubble { say(bubble, hold: 3) }
    }

    /// push-to-talk session (Voice.swift): he leans in to listen; the status says so while the mic is open
    func listening(_ on: Bool) {
        if on { oneShot(.acknowledging, hold: 1.2); model.setStatus("listening") }
        else if model.status == "listening" { model.setStatus(offline ? "brain offline" : currentState) }
    }

    /// face-down: bored loop + dimmed lights while the brain is idle; picked up: lights back, wave
    func setSleeping(_ on: Bool) {
        guard on != sleeping else { return }
        sleeping = on
        model.scene.setDim(on ? 0.35 : 1)
        let idleNow = currentState == "idle" || offline
        if on {
            idleTimer?.invalidate(); smokeTimer?.invalidate()
            model.laState = "sleeping"
            if idleNow { loop(idleClip); model.setStatus("asleep (face down)") }
        } else {
            if model.laState == "sleeping" { model.laState = "idle" }
            if idleNow { loop(idleClip); model.setStatus(offline ? "brain offline" : "idle") }
            oneShot(.wave, hold: 2.2)
            if idleNow { scheduleIdleLife(); scheduleSmoke() }
        }
    }

    /// battery < 20 % or Low Power Mode: bored loop, no smoke breaks, status "low battery"
    func setLowBattery(_ on: Bool) {
        guard on != lowBattery else { return }
        lowBattery = on
        let idleNow = currentState == "idle" || offline
        if on { smokeTimer?.invalidate(); model.setStatus("low battery") }
        if idleNow { loop(idleClip); if !on { model.setStatus(offline ? "brain offline" : "idle"); scheduleSmoke() } }
    }

    /// Settings > Background changed: swap the idle loop (walk <-> stand) if he is idle right now.
    func backgroundChanged() {
        guard model.sceneLoaded else { return }
        if currentState == "idle" || offline {
            let clip: Clip = offline && idleClip != .walk ? .bored : idleClip
            Log.add("background -> idle loop \(clip.rawValue)")
            loop(clip)
            if !model.synced { scheduleIdleLife() }
        }
    }

    // MARK: entry
    func handle(_ ev: [String: Any]) {
        guard let type = ev["type"] as? String else { return }
        let text = (ev["text"] as? String) ?? ""
        switch type {
        case "agents":
            model.agents = ((ev["list"] as? [[String: Any]]) ?? []).compactMap(AgentInfo.init)
        case "hello":
            model.brainBusy = (ev["busy"] as? Bool) ?? false
            if let list = ev["agents"] as? [[String: Any]] { model.agents = list.compactMap(AgentInfo.init) }
            model.setAsks((ev["asks"] as? [[String: Any]]) ?? [])               // 0.16
            model.synced = (ev["sync"] as? Bool) ?? false && ev["clock"] != nil
            if model.synced { idleTimer?.invalidate(); smokeTimer?.invalidate() }
            oneShot(.wave, hold: 2.2)
            say("hi, ask me anything", hold: 3)
        case "state":
            setState((ev["state"] as? String) ?? "idle")
        case "text":
            let clean = text.replacingOccurrences(of: #"\s*\[\w+\]"#, with: "", options: .regularExpression)
            model.lastLine = clean
            loop(talkFlip ? .talkingFunny : .explain); talkFlip.toggle()
            say(clean, hold: min(20, 6 + 0.03 * Double(clean.count)))
            model.addCard("say", clean)
            model.voice.speak(clean)                                  // 0.12: spoken reply (Settings > Speak replies)
        case "tool":
            onTool(ev)
        case "result":
            let ok = (ev["ok"] as? Bool) ?? false
            let summary = (ev["summary"] as? String) ?? ""
            model.lastOk = ok; model.laState = ok ? "celebrating" : "failing"
            if !summary.isEmpty { model.lastLine = summary }
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
            model.laState = "waiting"; model.lastLine = "? \(text)"
            loop(.think)
            say("? \(text)", hold: 20)
            model.setStatus("needs you")
            model.addCard("ask", text)
            if let a = model.parseAsk(ev) { model.addAsk(a) }                 // 0.16: Allow / Deny card + Lock Screen
        case "ask_resolved":
            let id = (ev["id"] as? String) ?? "", answer = (ev["answer"] as? String) ?? ""
            guard model.asks.contains(where: { $0.id == id }) else { break }
            model.resolveAsk(id, answer: answer, by: (ev["by"] as? String) ?? "")
            if model.asks.isEmpty {                                         // the question is gone: bubble, status, pose
                if model.bubble?.hasPrefix("? ") == true { model.setBubble(nil, hold: 0) }
                model.setStatus(answer == "allow" ? "allowed" : answer == "deny" ? "denied" : "no answer")
                if !model.brainBusy { loop(idleClip) }
                if answer == "allow" { oneShot(.nod, hold: 1.2) } else if answer == "deny" { oneShot(.acknowledging, hold: 1) }
            }
        case "snapshot":
            if let list = ev["asks"] as? [[String: Any]] { model.setAsks(list) }
        case "point":
            oneShot(.explain, hold: 3)
            say((ev["label"] as? String) ?? "there", hold: 4)
        case "user_chat":
            if ev["local"] == nil, model.brainBusy { oneShot(.acknowledging, hold: 1) }
            if ev["local"] != nil { model.brainBusy = true; turnHadExec = false; model.setStatus("sent") }
        case "beat":
            onBeat(ev)
        case "brain_down":
            offline = true
            loop(idleClip == .walk ? .walk : .bored); model.setStatus("brain offline"); model.brainBusy = false   // street: he keeps strolling
            scheduleIdleLife(); scheduleSmoke()                     // local fallback while the brain is away
        case "brain_up":
            offline = false
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
        case "thinking": model.laState = "thinking"
        case "working", "talking": model.laState = "working"
        case "idle":
            // keep "celebrating"/"failing" on the Island until the reaction one-shot has played out, then idle
            let wait = max(0, oneShotUntil - CACurrentMediaTime())
            if wait == 0 || (model.laState != "celebrating" && model.laState != "failing") { model.laState = "idle" }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.1) { [weak self] in if let self, self.currentState == "idle", self.model.laState != "smoking" { self.model.laState = "idle" } } }
        default: break
        }
        switch s {
        case "idle":
            model.brainBusy = false; loop(idleClip); model.setStatus("idle")
            if model.synced { idleTimer?.invalidate(); smokeTimer?.invalidate() } else { scheduleIdleLife(); scheduleSmoke() }   // synced: the brain sends idle_life beats
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
            model.lastTool = summary.isEmpty ? name : "\(name) \(summary)"
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

    /// Director beats. Unsynced: one-shot reactions we can play (react/emote/celebrate/use_prop) and their bubbles.
    /// Synced (hello.sync + beat.t0): the clip starts `brainNow() - t0` seconds in so the phone shows the desktop's frame;
    /// idle_life beats (clip or clip_seq, incl. the smoke sequence) replace the local idle life, music_playing beats
    /// map the desk dance to the closest clip and put the beat's status ("listening: ...") in the status line.
    private func onBeat(_ ev: [String: Any]) {
        guard let beats = ev["beats"] as? [[String: Any]] else { return }
        let rule = (ev["rule"] as? String) ?? ""
        let t0 = ev["t0"] as? Double
        let synced = model.synced && t0 != nil
        let offset = synced ? max(0, model.brainNow() - t0!) : 0
        for b in beats {
            let verb = (b["verb"] as? String) ?? ""
            let seq = (b["clip_seq"] as? [String]) ?? []
            let rawName = (b["clip"] as? String) ?? seq.first ?? ""
            let raw = rawName.split(separator: "@").first.map(String.init) ?? ""
            let isLoop = (b["loop"] as? Bool) ?? false
            let clip = clipAliases[raw].flatMap { model.scene.has($0.rawValue) ? $0 : nil }
            if synced, let clip { Log.add(String(format: "beat %@: %@ -> %@ @%.2fs", rule, rawName, clip.rawValue, offset)) }
            let isSmoke = clip == .smokeLight || clip == .smokeExhale || seq.contains { $0.hasPrefix("vid_smoke") }
            if synced, rule == "music_playing" {
                if let clip { loop(clip, offset: offset) }
                if let status = b["status"] as? String { model.setStatus(status.hasPrefix("listening") ? status : "listening: \(status)") }
                else if (b["bubble"] as? String) != nil { model.setStatus("listening") }
                if let bubble = b["bubble"] as? String { say(bubble, hold: 4) }
                continue
            }
            if synced, rule == "idle_life", let clip {
                if isSmoke { if model.cigarOn, offset < 2 { smokeNow() }; continue }
                let d = model.scene.duration(of: clip.rawValue)
                if offset < d { oneShot(clip, hold: d - offset, offset: offset) }
                continue
            }
            if clip != nil, isSmoke { if model.cigarOn, offset < 2 { smokeNow() }; continue }
            if let clip, !isLoop, ["react", "emote", "celebrate", "use_prop"].contains(verb) {
                let hold = (b["max_hold_s"] as? Double) ?? model.scene.duration(of: clip.rawValue)
                if offset < hold { oneShot(clip, hold: hold - offset, offset: offset) }
            } else if synced, let clip, isLoop, ["idle", "act", "say"].contains(verb), !(verb == "idle" && idleClip == .walk) {   // street: keep walking
                loop(clip, offset: offset)
            }
            if let bubble = b["bubble"] as? String, (b["bubble_style"] as? String) == "aside" { say(bubble, hold: 3) }
            if let status = b["status"] as? String, verb == "gaze" { model.setStatus(status) }
        }
    }

    // MARK: playback helpers
    private func loop(_ clip: Clip, offset: TimeInterval = 0) {
        baseLoop = clip
        if CACurrentMediaTime() >= oneShotUntil { model.scene.play(clip.rawValue, loop: true, offset: offset) }
    }

    private func oneShot(_ clip: Clip, hold: TimeInterval, offset: TimeInterval = 0, then: (() -> Void)? = nil) {
        oneShotUntil = CACurrentMediaTime() + hold
        model.scene.play(clip.rawValue, loop: false, offset: offset)
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
        if model.synced || sleeping || lowBattery { return }
        smokeTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 45...120), repeats: false) { [weak self] _ in
            guard let self, self.currentState == "idle", self.model.cigarOn, !self.model.synced else { return }
            self.smokeNow()
            self.scheduleSmoke()
        }
    }

    /// TestMode: a take started `offset` s in, as a Director one-shot so the base loop comes back when it ends (playing it
    /// straight on the scene left him in the bind pose after the take: 0.14 simulator shot nebula_smoke2 at 15 s).
    func playTake(_ clip: Clip, offset: TimeInterval) {
        idleTimer?.invalidate()
        oneShot(clip, hold: max(0.1, model.scene.duration(of: clip.rawValue) - offset - 0.25), offset: offset)
    }

    func smokeNow() {
        guard model.scene.has(Clip.smokeExhale.rawValue) else { Log.add("no smoke take in the glb"); return }
        idleTimer?.invalidate()
        if currentState == "idle" { model.laState = "smoking" }
        let exhale = { [weak self] in
            guard let self else { return }
            self.oneShot(.smokeExhale, hold: self.model.scene.duration(of: Clip.smokeExhale.rawValue)) { [weak self] in
                guard let self else { return }
                if self.model.laState == "smoking" { self.model.laState = "idle" }
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
        if model.synced || sleeping { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 8...20), repeats: false) { [weak self] _ in
            guard let self, self.currentState == "idle" || self.offline, !self.model.synced else { return }
            if self.idleClip == .walk {
                // walking: no fidgets every few seconds (each one stops the street); now and then he pauses to look around
                if Double.random(in: 0...1) < 0.35 { self.oneShot(.look, hold: 4) }
            } else if self.currentState == "idle" {
                let pick = [Clip.shift, Clip.look, Clip.breathe].randomElement()!
                self.oneShot(pick, hold: min(8, self.model.scene.duration(of: pick.rawValue)))
            }
            self.scheduleIdleLife()
        }
    }
}
