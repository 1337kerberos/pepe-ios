// Phone-native voice (0.12): push-to-talk with on-device speech recognition, and spoken replies.
//  - PTT: the mic button in the app, or the PiP play/pause button while the brain is idle, opens a 6 s
//    SFSpeechRecognizer session (on-device when the locale supports it); partial text shows in the bubble, the final
//    transcript is sent to the brain as {"type":"chat"}. Tap again to stop early (and send).
//  - TTS: every brain `text` event is spoken with AVSpeechSynthesizer (Settings > Speak replies, default on); a new text
//    cuts the previous one off; the voice is the best installed (premium > enhanced > default) for the text's language
//    (NaturalLanguage guess), so an English reply gets an English voice and a Ukrainian one a Ukrainian voice.
//
// Audio session (AudioKeepAlive.configureSession, PepeApp.swift): with "Microphone" on (default) the app runs ONE session
// for its whole life: .playAndRecord + [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP].
//  - PiP keep-alive: the silent AVAudioEngine loop plays on that session exactly as on .playback (playAndRecord is a
//    playback-capable category; UIBackgroundModes=audio covers it), so the process stays alive under PiP. Video-call apps
//    run sample-buffer PiP on playAndRecord, which is the configuration Apple documents for PiP + mic.
//  - .defaultToSpeaker: playAndRecord would otherwise route TTS to the earpiece receiver.
//  - .mixWithOthers: the user's music keeps playing; Pepe's voice mixes over it (no ducking).
//  - Bluetooth: .allowBluetoothA2DP keeps AirPods on the high-quality output profile. The brief suggested .allowBluetooth
//    (HFP) too, but with both set iOS prefers HFP for a device that has it, i.e. the user's music on AirPods would turn
//    into phone-call quality for as long as Pepe floats. So the mic is the phone's own mic; flip `VoiceIO.useHFPMic` to
//    true to get the AirPods mic at that cost.
//  - Recording starts only inside a PTT session (a second AVAudioEngine's input tap), so the orange mic dot shows only
//    then; the keep-alive engine never touches its input node.
//  - If PiP stops working on this category, Settings > Microphone off returns to the 0.11 session (.playback +
//    .mixWithOthers); PTT is then disabled, TTS still works.
// Background: recognition while the app is backgrounded under PiP is reported to fail with kAFAssistantErrorDomain 1700
// on some iOS versions (Apple forum thread 112225, unverified for iOS 27); the error is logged and shown in the bubble.
// Permissions (mic + speech) can only be asked in the foreground: the first PTT from the PiP card without them tells the
// user to open the app once.
import Foundation
import AVFoundation
import Speech
import NaturalLanguage
import UIKit

enum VoiceIO {
    static let useHFPMic = false
    static let listenSeconds: TimeInterval = 6
    static let languages: [(id: String, label: String)] = [("auto", "auto (phone language)"), ("en-US", "English (US)"), ("uk-UA", "Ukrainian"), ("ru-RU", "Russian")]
}

final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    unowned let model: PepeModel
    private let synth = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var stopTimer: Timer?
    private var finishTimer: Timer?
    private var transcript = ""
    private var finished = true
    private var voices: [String: AVSpeechSynthesisVoice] = [:]

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

    // MARK: push-to-talk
    var permissionsGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized && AVAudioApplication.shared.recordPermission == .granted
    }

    func requestPermissions(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVAudioApplication.requestRecordPermission { mic in
                DispatchQueue.main.async {
                    Log.add("voice permissions: speech \(status == .authorized ? "authorized" : "status \(status.rawValue)"), mic \(mic ? "granted" : "denied")")
                    done(status == .authorized && mic)
                }
            }
        }
    }

    /// mic button / PiP play-pause: start a 6 s session, or stop the running one early (and send what was heard)
    func toggle(fromPiP: Bool) {
        if model.listening { stop(); return }
        guard model.micOn else { model.setBubble("microphone is off (Settings > Voice)", hold: 3); return }
        guard permissionsGranted else {
            if fromPiP || UIApplication.shared.applicationState != .active {
                model.setBubble("open Pepe once to allow the mic + speech", hold: 5); Log.add("voice: no permission (asked from the background)")
                return
            }
            requestPermissions { [weak self] ok in
                if ok { self?.start() } else { self?.model.setBubble("mic or speech permission denied (iOS Settings > Pepe)", hold: 5) }
            }
            return
        }
        start()
    }

    private var locale: Locale {
        let pick = model.speechLang
        if pick != "auto" { return Locale(identifier: pick) }
        let cur = Locale.current
        let supported = SFSpeechRecognizer.supportedLocales()
        if supported.contains(where: { $0.identifier == cur.identifier }) { return cur }
        if let lang = cur.language.languageCode?.identifier, let any = supported.first(where: { $0.language.languageCode?.identifier == lang }) { return any }
        return Locale(identifier: "en-US")
    }

    private func start() {
        let loc = locale
        guard let rec = SFSpeechRecognizer(locale: loc), rec.isAvailable else {
            model.setBubble("speech recognition unavailable for \(loc.identifier)", hold: 4); Log.add("voice: recognizer unavailable \(loc.identifier)"); return
        }
        stopSpeaking()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = true
        let onDevice = rec.supportsOnDeviceRecognition
        if onDevice { req.requiresOnDeviceRecognition = true }
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            model.setBubble("no microphone input (Settings > Voice > Microphone?)", hold: 4); Log.add("voice: input format \(fmt) (session category \(AVAudioSession.sharedInstance().category.rawValue))"); return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in req.append(buf) }
        eng.prepare()
        do { try eng.start() } catch {
            input.removeTap(onBus: 0)
            model.setBubble("mic failed: \(error.localizedDescription)", hold: 4); Log.add("voice: engine start \(error)"); return
        }
        engine = eng; request = req; transcript = ""; finished = false
        model.listening = true
        model.director.listening(true)
        model.setBubble("listening...", hold: VoiceIO.listenSeconds + 3)
        Log.add("voice: listening \(loc.identifier) (\(onDevice ? "on-device" : "server"), \(Int(fmt.sampleRate)) Hz)")
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, !self.finished else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if !self.transcript.isEmpty { self.model.setBubble("\u{201C}\(self.transcript)\u{201D}", hold: 4) }
                    if result.isFinal { self.finish(reason: "final") }
                } else if let error {
                    Log.add("voice: recognition error \(error.localizedDescription) (\((error as NSError).domain) \((error as NSError).code))")
                    self.finish(reason: "error")
                }
            }
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: VoiceIO.listenSeconds, repeats: false) { [weak self] _ in self?.stop() }
    }

    /// end of the 6 s window (or an early tap): close the audio, wait up to 2 s for the final result
    private func stop() {
        guard model.listening else { return }
        stopTimer?.invalidate(); stopTimer = nil
        closeAudio()
        model.listening = false
        finishTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.finish(reason: "timeout") }
    }

    private func closeAudio() {
        if let eng = engine { eng.inputNode.removeTap(onBus: 0); eng.stop() }
        engine = nil
        request?.endAudio()
    }

    private func finish(reason: String) {
        guard !finished else { return }
        finished = true
        stopTimer?.invalidate(); finishTimer?.invalidate()
        if model.listening { closeAudio(); model.listening = false }
        task?.cancel(); task = nil; request = nil
        model.director.listening(false)
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.add("voice: \(reason), heard \"\(text)\"")
        if text.isEmpty { model.setBubble("didn't catch that", hold: 3); return }
        model.setBubble("you: \(text)", hold: 4)
        model.send(chat: text)
    }

    // AVSpeechSynthesizerDelegate: keep the log honest about what was said
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Log.add("tts: speaking \(utterance.speechString.count) chars")
    }
}
