// Simulator / UI test mode (CI: .github/workflows/ios-sim.yml + tools/sim_shots.sh). Launch with `-uiTest 1` plus any of:
//   -background ops|street|nebula|lounge|office|neon|plain   -streetTime auto|dawn|day|dusk|night   -pipMode videoCall|sampleBuffer
//   -nebulaVideo output|player|still   -cardSize threeFour|nineSixteen|square
//   (those are plain UserDefaults keys: the argument domain overrides the saved settings for this launch)
//   -testState working|thinking|celebrating|failing|smoking   -stateAt <s since launch, default 2>
//   -exhaleAt <s>      play the smoke_exhale take from 4.25 s in: the exhale (baked cards or particles) fires at once
//   -reaction squash|stumble|sleep|wake   -reactAt <s>      -bubble <text>      -smokeDebug 1 (cards drawn as UV + alpha)
//   0.15: -voiceDemo listening|recognizing|sent|error [-voiceAt <s>]  the mic panel in that state (no audio in the sim)
//         -talkMode tap|hold   -openSettings main|debug|live [-settingsAt <s>] [-debugAnchor log]
//         -liveStart <s>      Settings > Live Activity > Start at that time (logs the request result)
//   0.16: -ask 1 (or -uiTest ask=1) [-askAt <s>, default 3] [-askTTL <s>, default 300] [-askResolveAt <s>]
//         a fake pending brain ask from the Claude Code gate: the app card, the Live Activity (Lock Screen preview in
//         Settings > Live Activity, Allow / Deny + countdown in the Island) show it; -askResolveAt resolves it (allow, pocket)
// The brain is never dialled (no Bonjour, no WebSocket), the launch exhale is off, so every run is deterministic.
import Foundation
import QuartzCore

enum TestMode {
    static let args = ProcessInfo.processInfo.arguments
    static let on = args.contains("-uiTest")
    static let launch = CACurrentMediaTime()
    static func value(_ key: String) -> String? {
        guard let i = args.firstIndex(of: "-" + key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static func time(_ key: String) -> TimeInterval? { value(key).flatMap(Double.init) }

    private static func at(_ t: TimeInterval, _ what: String, _ block: @escaping () -> Void) {
        let delay = max(0, t - (CACurrentMediaTime() - launch))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Log.add(String(format: "TEST t=%.2fs: %@", CACurrentMediaTime() - launch, what)); block()
        }
    }

    /// called once the scene is loaded
    static func run(model: PepeModel) {
        Log.add(String(format: "TEST MODE (scene loaded at %.2fs): %@", CACurrentMediaTime() - launch, args.dropFirst().joined(separator: " ")))
        let d = model.director!
        if let st = value("testState") {
            at(time("stateAt") ?? 2, "state \(st)") {
                switch st {
                case "working":
                    d.handle(["type": "state", "state": "working"]); d.handle(["type": "tool", "phase": "start", "name": "Bash", "summary": "swift build"])
                case "thinking": d.handle(["type": "state", "state": "thinking"])
                case "celebrating":
                    d.handle(["type": "state", "state": "working"]); d.handle(["type": "tool", "phase": "start", "name": "Bash", "summary": "swift test"])
                    d.handle(["type": "result", "ok": true, "summary": "all 42 tests passed"])
                case "failing": d.handle(["type": "result", "ok": false, "summary": "3 tests failed"])
                case "smoking": d.smokeNow()
                default: Log.add("TEST: unknown testState \(st)")
                }
            }
        }
        if let t = time("exhaleAt") {
            at(t, "exhale (smoke_exhale from 4.25 s)") { d.playTake(.smokeExhale, offset: 4.25) }
        }
        if let r = value("reaction") {
            at(time("reactAt") ?? 4, "reaction \(r)") {
                switch r {
                case "squash": model.scene.squash(); d.react(.veryHappy)
                case "stumble": model.scene.squash(amount: 0.1); d.react(.angry, hold: 1)
                case "sleep": d.setSleeping(true)
                case "wake": d.setSleeping(false)
                default: Log.add("TEST: unknown reaction \(r)")
                }
            }
        }
        if let b = value("bubble") { at(1, "bubble") { model.setBubble(b, hold: 30) } }
        if value("smokeDebug") == "1" { model.scene.setSmokeDebug(true) }
        if let v = value("voiceDemo") { at(time("voiceAt") ?? 4, "voice demo \(v)") { model.voice.demo(v) } }
        if let t = time("liveStart") {
            at(t, "live activity start") {
                LiveActivityManager.shared.start(model.liveActivityContent(), reason: "test")
                let la = LiveActivityManager.shared
                Log.add("TEST live activity: phase \(la.phase), enabled \(LiveActivityManager.enabled), widget \(LiveActivityManager.widgetPresent), error \(la.lastError.isEmpty ? "none" : la.lastError)")
            }
        }
        if value("ask") == "1" || value("uiTest") == "ask=1" {
            at(time("askAt") ?? 3, "ask demo") {
                d.handle(["type": "ask", "id": "test-ask-1", "text": "solana-microstructure wants to run: git push origin main (changes git history or the remote)",
                          "kind": "tool", "options": ["allow", "deny"], "ttl_s": time("askTTL") ?? 300, "expires": model.brainNow() + (time("askTTL") ?? 300),
                          "origin": "claude-code", "tool": "Bash", "cwd": "solana-microstructure", "agent": "e2e0babe"])
                let la = LiveActivityManager.shared
                Log.add("TEST ask demo: pending \(model.asks.count), live activity ask \(model.liveActivityContent().ask?.id ?? "none"), state \(model.liveActivityContent().state), activity \(la.phase), alerts \(la.alerts)")
            }
            if let r = time("askResolveAt") {
                at(r, "ask resolved") { d.handle(["type": "ask_resolved", "id": "test-ask-1", "answer": "allow", "by": "pocket"]); Log.add("TEST ask resolved: pending \(model.asks.count)") }
            }
        }
        Log.add("TEST install: \(InstallInfo.kind), widget \(LiveActivityManager.widgetPresent ? "present" : "missing"), mic \(Voice.micStatus), speech \(Voice.speechStatus), recognizer \(model.voice.recognizerSummary), session \(AudioKeepAlive.categorySummary)")
    }
}
