// Phone-native voice (0.12, reworked in 0.15 after the first device test: "the mic doesn't hold, releasing gives
// 'didn't catch that'").
//  - Talk mode (Settings > Voice > Talk mode, launch arg `-talkMode tap|hold`):
//      tap  (default): tap the mic to start; tap again, or 2 s without a new word, stops and sends. Before the first word
//            the window waits up to 10 s; 30 s hard cap.
//      hold: press and hold to talk, release to send (a DragGesture(minimumDistance: 0) on a plain view, not a Button:
//            a SwiftUI Button only fires on release, which is exactly what 0.12-0.14 did: the hold did nothing and the
//            release STARTED a 6 s window after the user had finished talking -> "didn't catch that").
//    The PiP play/pause button is always tap-style (start / stop).
//  - Under the mic button (ContentView.MicPanel): a state label (idle / asking permission / listening / recognizing /
//    sending / sent / error), a live mic level meter, the live partial transcript, and one line with the last result or
//    error. Every failure path writes that line (and the log), nothing fails silently.
//  - Recognition: SFSpeechRecognizer for the chosen locale (auto = the phone's language, normalised en_US -> en-US, best
//    match picked deterministically). On-device when the locale supports it and Settings > Voice > "Prefer on-device" is
//    on; if the on-device task errors, or ends with no text although the mic clearly heard speech, the SAME audio (every
//    buffer is kept for the session, max 60 s) is replayed into a server-side request. The log/line say which path won.
//  - Audio: the input tap is installed before AVAudioEngine.start(); right before a session the shared AVAudioSession is
//    re-checked and switched back to .playAndRecord if something (PiP, another app) left it elsewhere.
//  - TTS: every brain `text` event is spoken with AVSpeechSynthesizer (Settings > Speak replies), best installed voice
//    for the text's language.
//
// Audio session (AudioKeepAlive.configureSession, PepeApp.swift): with "Microphone" on (default) one session for the app's
// life: .playAndRecord + [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP] (no HFP: AirPods music would drop to
// call quality while Pepe floats; `VoiceIO.useHFPMic`). Microphone off = .playback (PTT disabled, TTS works).
// Background: recognition started from the PiP card while backgrounded may fail with kAFAssistantErrorDomain 1700.
import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import UIKit

enum VoiceIO {
    static let useHFPMic = false
    static let languages: [(id: String, label: String)] = [("auto", "auto (phone language)"), ("en-US", "English (US)"), ("uk-UA", "Ukrainian"), ("ru-RU", "Russian")]
    static let silenceStop: TimeInterval = 2       // tap mode: stop this long after the last new word
    static let firstWordWait: TimeInterval = 10    // tap mode: give up if nothing was recognised by then
    static let tapCap: TimeInterval = 30
    static let holdCap: TimeInterval = 60
    static let speechDb: Float = -42               // mic level above this counts as "heard something" (diagnostics, server retry)
}

/// What the mic panel shows; separate from PepeModel so the 10-20 Hz level updates only redraw the panel.
final class VoiceUI: ObservableObject {
    enum Phase: String { case idle, asking = "asking permission", starting, listening, recognizing, sending, sent, error }
    @Published var phase: Phase = .idle
    @Published var partial = ""
    @Published var level: Float = 0          // 0...1 (-60...0 dB)
    @Published var line = ""                 // last result / error / hint
    @Published var lineIsError = false
    @Published var route = ""                // "en-US · on-device" while a session runs
    @Published var showOpenSettings = false  // a permission was denied: offer iOS Settings

    var label: String {
        switch phase {
        case .idle: return "mic idle"
        case .asking: return "asking for mic + speech permission"
        case .starting: return "starting mic"
        case .listening: return "listening"
        case .recognizing: return "recognizing"
        case .sending: return "sending"
        case .sent: return "sent"
        case .error: return "error"
        }
    }
}

final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    unowned let model: PepeModel
    let ui = VoiceUI()
    private let synth = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tick: Timer?
    private var finishTimer: Timer?
    private var transcript = ""
    private var finished = true
    private var holdSession = false
    private var startedAt: TimeInterval = 0
    private var lastWordAt: TimeInterval = 0
    private var usingOnDevice = false
    private var retriedServer = false
    private var lastError = ""
    private var voices: [String: AVSpeechSynthesisVoice] = [:]
    private var idleReset: DispatchWorkItem?

    // audio thread state (the tap), guarded by `lock`
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var captured: [AVAudioPCMBuffer] = []
    private var capturedFrames: AVAudioFramePosition = 0
    private var captureLimit: AVAudioFramePosition = 48_000 * 60
    private var peakDb: Float = -160
    private var buffersSeen = 0

    init(model: PepeModel) {
        self.model = model
        super.init()
        synth.delegate = self
        synth.usesApplicationAudioSession = true      // speak on our session (keeps working under PiP, mixes with music)
    }

    // MARK: TTS
    func speak(_ raw: String) {
        guard model.speakReplies, !model.listening else { return }
        let text = Voice.clean(raw)
        guard !text.isEmpty else { return }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice(for: text)
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        u.volume = 1
        synth.speak(u)
    }

    func stopSpeaking() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }

    /// markdown / code / tags out, URLs shortened, capped: the bubble shows the full text, the voice the gist
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (code) ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*\[\w+\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"https?://\S+"#, with: "a link", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[`*_#>|]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if t.count > 400 { t = String(t.prefix(400)) + "..." }
        return t
    }

    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue ?? "en"
        if let v = voices[lang] { return v }
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(lang) }
        let preferred = lang == "en" ? all.filter { $0.language == "en-US" } : all
        let pick = (preferred.isEmpty ? all : preferred).max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
        voices[lang] = pick
        let q = pick.map { $0.quality == .premium ? "premium" : $0.quality == .enhanced ? "enhanced" : "default" } ?? "-"
        Log.add("tts voice for \(lang): \(pick?.name ?? "system default") \(pick?.language ?? "") (\(q); \(all.count) installed)")
        return pick
    }

    // MARK: permissions
    static var speechStatus: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "authorized"; case .denied: return "DENIED"; case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"; @unknown default: return "unknown"
        }
    }
    static var micStatus: String {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return "granted"; case .denied: return "DENIED"; case .undetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
    var permissionsGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
    }
    /// iOS kills the process when a privacy API is touched without its usage string in the RUNNING app's Info.plist
    /// (inside LiveContainer that is the host's plist), so check before asking.
    static var usageStringsPresent: (mic: Bool, speech: Bool) {
        (Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
         Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil)
    }

    private func requestPermissions(_ done: @escaping (Bool) -> Void) {
        let u = Voice.usageStringsPresent
        guard u.mic, u.speech else {
            fail("this install's Info.plist has no \(u.mic ? "" : "microphone ")\(u.speech ? "" : "speech ")usage text (LiveContainer host?), iOS would kill the app if asked", permission: false)
            done(false); return
        }
        ui.phase = .asking; ui.line = ""; ui.lineIsError = false
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { mic in
                DispatchQueue.main.async {
                    Log.add("voice permissions: speech \(Voice.speechStatus) (raw \(status.rawValue)), mic \(mic ? "granted" : "denied")")
                    done(status == .authorized && mic)
                }
            }
        }
    }

    // MARK: entry points
    /// tap mode mic button, the PiP play/pause button: start, or stop the running session (and send)
    func toggle(fromPiP: Bool) {
        if model.listening { stop(reason: "tap"); return }
        begin(fromPiP: fromPiP, hold: false)
    }
    /// hold mode: finger down / finger up
    func pressBegan() { if !model.listening { begin(fromPiP: false, hold: true) } }
    func pressEnded() {
        if model.listening { stop(reason: "released") }
        else if ui.phase == .asking { pendingStartAfterPermission = false }
    }
    private var pendingStartAfterPermission = false

    private func begin(fromPiP: Bool, hold: Bool) {
        guard model.micOn else { fail("microphone is off (Settings > Voice > Microphone)", permission: false); return }
        guard !finished || ui.phase != .recognizing else { Log.add("voice: still recognizing the last take"); return }
        guard permissionsGranted else {
            let denied = SFSpeechRecognizer.authorizationStatus() == .denied || AVAudioApplication.shared.recordPermission == .denied
            if denied { fail("mic \(Voice.micStatus), speech \(Voice.speechStatus): allow both in iOS Settings > Pepe", permission: true); return }
            if fromPiP || UIApplication.shared.applicationState != .active {
                fail("open Pepe once to allow the mic + speech (iOS can't ask from the PiP card)", permission: false)
                model.setBubble("open Pepe once to allow the mic + speech", hold: 5); return
            }
            pendingStartAfterPermission = true
            requestPermissions { [weak self] ok in
                guard let self else { return }
                if !ok { self.fail("mic \(Voice.micStatus), speech \(Voice.speechStatus): allow both in iOS Settings > Pepe", permission: true); return }
                // the system alert ate the hold gesture's release: in hold mode the user presses again
                if hold { self.setIdle(line: "permission granted: press and hold the mic again"); return }
                if self.pendingStartAfterPermission { self.start(hold: false) }
            }
            return
        }
        start(hold: hold)
    }

    // MARK: locale
    /// SFSpeechRecognizer's supported locales use "en-US"; Locale.current is "en_US" (or "en_UA" for a mixed setup).
    static func norm(_ id: String) -> String { id.replacingOccurrences(of: "_", with: "-") }

    var locale: Locale {
        let pick = model.speechLang
        if pick != "auto" { return Locale(identifier: pick) }
        let supported = SFSpeechRecognizer.supportedLocales().map { Voice.norm($0.identifier) }.sorted()
        let cur = Locale.current
        let curId = Voice.norm(cur.identifier).components(separatedBy: "@").first ?? ""
        if supported.contains(curId) { return Locale(identifier: curId) }
        let lang = cur.language.languageCode?.identifier ?? "en"
        let region = cur.region?.identifier ?? ""
        let preferred = ["en": "en-US", "uk": "uk-UA", "ru": "ru-RU", "de": "de-DE", "fr": "fr-FR", "es": "es-ES", "pt": "pt-BR"]
        for cand in ["\(lang)-\(region)", preferred[lang] ?? ""] where supported.contains(cand) { return Locale(identifier: cand) }
        if let any = supported.first(where: { $0.hasPrefix(lang + "-") }) { return Locale(identifier: any) }
        return Locale(identifier: "en-US")
    }

    /// For the diagnostics panel: locale, availability, on-device support.
    var recognizerSummary: String {
        let loc = locale
        guard let r = SFSpeechRecognizer(locale: loc) else { return "\(Voice.norm(loc.identifier)): NO recognizer for this locale" }
        return "\(Voice.norm(loc.identifier)): available \(r.isAvailable ? "yes" : "NO"), on-device \(r.supportsOnDeviceRecognition ? "supported" : "not supported")\(model.preferOnDevice ? "" : " (off by setting)")"
    }

    // MARK: session
    private func start(hold: Bool) {
        pendingStartAfterPermission = false
        idleReset?.cancel()
        let loc = locale
        let locId = Voice.norm(loc.identifier)
        guard let rec = SFSpeechRecognizer(locale: loc) else { fail("no speech recognizer for \(locId): pick a language in Settings > Voice", permission: false); return }
        guard rec.isAvailable else { fail("speech recognition unavailable for \(locId) (offline? Siri & Dictation off?)", permission: false); return }
        ui.phase = .starting
        stopSpeaking()

        // the session: should be playAndRecord since launch, but PiP / other apps can change things under us
        let s = AVAudioSession.sharedInstance()
        do { try AudioKeepAlive.shared.ensureRecordSession() } catch {
            fail("audio session: \(error.localizedDescription)", permission: false); return
        }
        guard s.isInputAvailable else { fail("no audio input available (route \(AudioKeepAlive.routeSummary))", permission: false); return }

        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            fail("mic input has no format (\(fmt.sampleRate) Hz, \(fmt.channelCount) ch, category \(AudioKeepAlive.categorySummary))", permission: false); return
        }
        lock.lock()
        captured = []; capturedFrames = 0; captureLimit = AVAudioFramePosition(fmt.sampleRate * 60); peakDb = -160; buffersSeen = 0; request = nil
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in self?.onAudio(buf) }   // tap BEFORE start
        eng.prepare()
        do { try eng.start() } catch {
            input.removeTap(onBus: 0)
            fail("mic engine failed: \(error.localizedDescription) (\((error as NSError).code))", permission: false); return
        }
        engine = eng; recognizer = rec
        transcript = ""; finished = false; retriedServer = false; lastError = ""; holdSession = hold
        startedAt = CACurrentMediaTime(); lastWordAt = 0
        usingOnDevice = rec.supportsOnDeviceRecognition && model.preferOnDevice
        startTask(onDevice: usingOnDevice)
        model.listening = true
        model.director.listening(true)
        ui.phase = .listening; ui.partial = ""; ui.line = ""; ui.lineIsError = false; ui.showOpenSettings = false
        ui.route = "\(locId) · \(usingOnDevice ? "on-device" : "server")"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        model.setBubble(hold ? "listening... (release to send)" : "listening... (tap again to send)", hold: VoiceIO.holdCap)
        Log.add("voice: listening \(locId) (\(usingOnDevice ? "on-device" : "server"), \(Int(fmt.sampleRate)) Hz \(fmt.channelCount) ch, \(hold ? "hold" : "tap") mode, session \(AudioKeepAlive.categorySummary), input \(AudioKeepAlive.inputSummary))")
        tick?.invalidate()
        tick = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.onTick() }
    }

    /// a recognition task fed with everything captured so far, then live buffers
    private func startTask(onDevice: Bool) {
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        req.requiresOnDeviceRecognition = onDevice
        lock.lock()
        for b in captured { req.append(b) }
        let replayed = captured.count
        request = req
        let audioOpen = engine != nil
        lock.unlock()
        if !audioOpen { req.endAudio() }
        if replayed > 0 { Log.add("voice: \(onDevice ? "on-device" : "server") task fed \(replayed) captured buffers\(audioOpen ? " + live" : "")") }
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async { self?.onResult(result, error, onDevice: onDevice, req: req) }
        }
    }

    private func onAudio(_ buf: AVAudioPCMBuffer) {
        var db: Float = -160
        if let ch = buf.floatChannelData, buf.frameLength > 0 {
            var sum: Float = 0
            let n = Int(buf.frameLength), p = ch[0]
            for i in 0..<n { sum += p[i] * p[i] }
            db = 10 * log10(max(sum / Float(n), 1e-16))
        }
        let copy = Voice.copy(buf)
        lock.lock()
        request?.append(buf)
        if let copy, capturedFrames < captureLimit { captured.append(copy); capturedFrames += AVAudioFramePosition(copy.frameLength) }
        peakDb = max(peakDb, db); buffersSeen += 1
        lock.unlock()
        let level = max(0, min(1, (db + 60) / 60))
        DispatchQueue.main.async { [weak self] in self?.ui.level = level }
    }

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength) else { return nil }
        c.frameLength = b.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: b.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(c.mutableAudioBufferList)
        for i in 0..<min(src.count, dst.count) {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let n = min(src[i].mDataByteSize, dst[i].mDataByteSize)
            memcpy(d, s, Int(n)); dst[i].mDataByteSize = n
        }
        return c
    }

    private var heardSpeech: Bool { lock.lock(); defer { lock.unlock() }; return peakDb > VoiceIO.speechDb }
    private var peakSummary: String { lock.lock(); defer { lock.unlock() }; return String(format: "mic peak %.0f dB, %d buffers", peakDb, buffersSeen) }

    private func onTick() {
        guard model.listening else { return }
        let now = CACurrentMediaTime(), t = now - startedAt
        if holdSession {
            if t > VoiceIO.holdCap { stop(reason: "60 s cap") }
            return
        }
        if lastWordAt > 0, now - lastWordAt > VoiceIO.silenceStop { stop(reason: "2 s silence"); return }
        if lastWordAt == 0, t > VoiceIO.firstWordWait { stop(reason: "no words in 10 s"); return }
        if t > VoiceIO.tapCap { stop(reason: "30 s cap") }
    }

    private func onResult(_ result: SFSpeechRecognitionResult?, _ error: Error?, onDevice: Bool, req: SFSpeechAudioBufferRecognitionRequest) {
        guard !finished else { return }
        lock.lock(); let current = request === req; lock.unlock()
        guard current else { return }    // a replaced (on-device -> server) task still reporting
        if let result {
            let text = result.bestTranscription.formattedString
            if text != transcript, !text.isEmpty { lastWordAt = CACurrentMediaTime() }
            transcript = text
            ui.partial = text
            if !text.isEmpty { model.setBubble("\u{201C}\(text)\u{201D}", hold: 4) }
            if result.isFinal {
                if text.isEmpty, onDevice, !retriedServer, heardSpeech { retryOnServer(why: "on-device final was empty but the mic heard speech"); return }
                finish(reason: "final")
            }
        } else if let error {
            let ns = error as NSError
            lastError = "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
            Log.add("voice: recognition error (\(onDevice ? "on-device" : "server")) \(lastError)")
            if onDevice, !retriedServer, transcript.isEmpty { retryOnServer(why: "on-device error \(ns.code)"); return }
            finish(reason: "error")
        }
    }

    /// on-device failed: same audio, server-side recognizer (needs network + Siri & Dictation allowed)
    private func retryOnServer(why: String) {
        retriedServer = true
        usingOnDevice = false
        Log.add("voice: \(why) -> retrying on the server")
        task?.cancel()
        ui.route = ui.route.replacingOccurrences(of: "on-device", with: "server (on-device failed)")
        startTask(onDevice: false)
        if !model.listening {   // audio already closed: give the server time to answer
            finishTimer?.invalidate()
            finishTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in self?.finish(reason: "server timeout") }
        }
    }

    /// the user (or a timer) ends the take: close the mic, then wait up to 3 s for the final result
    func stop(reason: String) {
        guard model.listening else { return }
        Log.add("voice: stop (\(reason)), \(peakSummary)")
        tick?.invalidate(); tick = nil
        closeAudio()
        model.listening = false
        ui.phase = .recognizing; ui.level = 0
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        finishTimer?.invalidate()
        finishTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, !self.finished else { return }
            if self.transcript.isEmpty, self.usingOnDevice, !self.retriedServer, self.heardSpeech { self.retryOnServer(why: "on-device gave no text in 3 s"); return }
            self.finish(reason: "timeout")
        }
    }

    private func closeAudio() {
        if let eng = engine { eng.inputNode.removeTap(onBus: 0); eng.stop() }
        engine = nil
        lock.lock(); let r = request; lock.unlock()
        r?.endAudio()
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        tick?.invalidate(); tick = nil
        finishTimer?.invalidate(); finishTimer = nil
        if model.listening { closeAudio(); model.listening = false }
        task?.cancel(); task = nil
        lock.lock(); request = nil; captured = []; capturedFrames = 0; lock.unlock()
        model.director.listening(false)
        ui.level = 0
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = usingOnDevice ? "on-device" : "server"
        Log.add("voice: \(reason) (\(path)), heard \"\(text)\", \(peakSummary)")
        if text.isEmpty {
            let why: String
            if !lastError.isEmpty { why = "recognizer error \(lastError)" }
            else if !heardSpeech { why = "the mic stayed quiet (\(peakSummary)): wrong input route or muted?" }
            else { why = "speech was heard but not recognised (\(path), \(ui.route))" }
            model.setBubble("didn't catch that", hold: 3)
            fail("didn't catch that: \(why)", permission: false)
            return
        }
        ui.partial = text
        model.setBubble("you: \(text)", hold: 4)
        if !model.connected {
            ui.phase = .error; ui.lineIsError = true
            ui.line = "heard \u{201C}\(text)\u{201D} but the brain is offline: not sent"
            Log.add("voice: not sent, brain offline")
            scheduleIdle(after: 8)
            return
        }
        ui.phase = .sending
        model.send(chat: text)
        Log.add("voice: sent (\(path)\(retriedServer ? ", server retry" : ""))")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.ui.phase == .sending else { return }
            self.ui.phase = .sent; self.ui.lineIsError = false
            self.ui.line = "sent \u{201C}\(text)\u{201D} (\(path))"
            self.scheduleIdle(after: 6)
        }
    }

    private func fail(_ msg: String, permission: Bool) {
        Log.add("voice: \(msg)")
        ui.phase = .error; ui.line = msg; ui.lineIsError = true; ui.showOpenSettings = permission; ui.level = 0
        scheduleIdle(after: 12)
    }

    private func setIdle(line: String) {
        ui.phase = .idle; ui.line = line; ui.lineIsError = false; ui.showOpenSettings = false
        Log.add("voice: \(line)")
    }

    /// state label back to idle, the last line stays visible
    private func scheduleIdle(after s: TimeInterval) {
        idleReset?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.model.listening, self.finished || self.ui.phase == .error else { return }
            self.ui.phase = .idle; self.ui.partial = ""
        }
        idleReset = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }

    /// simulator screenshots (TestMode `-voiceDemo`): the panel in a given state, no audio
    func demo(_ state: String) {
        ui.route = "en-US · on-device"
        switch state {
        case "listening":
            ui.phase = .listening; ui.partial = "hey pepe, what's the build status"
            ui.line = "tap again (or stop talking for 2 s) to send"; ui.lineIsError = false
            model.listening = true; model.director.listening(true)
            let t0 = CACurrentMediaTime()
            tick = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                let t = CACurrentMediaTime() - t0
                self?.ui.level = Float(0.55 + 0.3 * sin(t * 7) * sin(t * 1.3))
            }
        case "recognizing": ui.phase = .recognizing; ui.partial = "hey pepe, what's the build status"
        case "sent": ui.phase = .sent; ui.line = "sent \u{201C}hey pepe, what's the build status\u{201D} (on-device)"
        default:
            ui.phase = .error; ui.lineIsError = true
            ui.line = "didn't catch that: recognizer error kAFAssistantErrorDomain 1110: No speech detected"
        }
        Log.add("voice demo: \(ui.phase.rawValue)")
    }

    // AVSpeechSynthesizerDelegate: keep the log honest about what was said
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Log.add("tts: speaking \(utterance.speechString.count) chars")
    }
}
