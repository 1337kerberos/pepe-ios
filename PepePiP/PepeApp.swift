// Pepe in Picture-in-Picture: app entry, audio keep-alive, app-wide model.
import SwiftUI
import AVFoundation

@main
struct PepeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = PepeModel.shared
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AudioKeepAlive.shared.configureSession()
        PepeIntentBridge.handler = { action in await PepeModel.shared.handleIntent(action) }
        return true
    }
}

/// A playback audio session + a looping silent buffer. With UIBackgroundModes=audio this keeps the process (and the
/// PiP frame feeder) alive after the user swipes home. App Store caveat: Apple rejects "silent audio to stay alive"
/// (guideline 2.5.4) and non-video PiP is a documented grey area; both are irrelevant for a sideloaded prototype.
final class AudioKeepAlive {
    static let shared = AudioKeepAlive()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    /// One session for the app's life (see Voice.swift for the reasoning): Microphone on (default) -> .playAndRecord +
    /// mixWithOthers / defaultToSpeaker / A2DP (push-to-talk + TTS + the PiP keep-alive on the same session);
    /// Microphone off -> the 0.11 session, .playback + mixWithOthers (TTS still works, PTT disabled).
    /// Called at launch and when the Microphone toggle changes (the keep-alive engine keeps running across the change;
    /// if it stops, AVAudioEngineConfigurationChange restarts it).
    func configureSession() {
        let mic = UserDefaults.standard.object(forKey: "micOn") as? Bool ?? true
        do {
            let s = AVAudioSession.sharedInstance()
            if mic {
                var opts: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
                if VoiceIO.useHFPMic { opts.insert(.allowBluetooth) }
                try s.setCategory(.playAndRecord, mode: .default, options: opts)
            } else {
                try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try s.setActive(true)
            Log.add("audio session: \(s.category.rawValue.replacingOccurrences(of: "AVAudioSessionCategory", with: "")) options \(s.categoryOptions.rawValue), output \(s.currentRoute.outputs.first?.portType.rawValue ?? "-")")
        } catch { Log.add("audio session: \(error)") }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                guard let self, self.running else { return }
                Log.add("keep-alive engine: configuration change -> restart")
                self.running = false; self.player.stop(); self.engine.stop(); self.start()
            }
        }
    }
    private var observing = false

    func start() {
        guard !running else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity // zeroed = one second of silence
        if player.engine == nil { engine.attach(player) }   // start() runs again after a configuration change
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: [.loops])
            player.play()
            running = true
        } catch { Log.add("audio engine: \(error)") }
    }

    func stop() {
        guard running else { return }
        player.stop(); engine.stop(); running = false
    }
}

/// Tiny in-app log (shown in Settings) so the phone can be debugged without a Mac.
enum Log {
    static var lines: [String] = []
    static var onChange: (() -> Void)?
    static func add(_ s: String) {
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(s)"
        if TestMode.on { fputs(line + "\n", stderr) } else { print(line) }   // stderr is unbuffered: the sim test kills the app
        DispatchQueue.main.async {
            lines.append(line); if lines.count > 200 { lines.removeFirst(lines.count - 200) }
            onChange?()
        }
    }
}
