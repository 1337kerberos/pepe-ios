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

    func configureSession() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
        } catch { Log.add("audio session: \(error)") }
    }

    func start() {
        guard !running else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
        buffer.frameLength = buffer.frameCapacity // zeroed = one second of silence
        engine.attach(player)
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
        print(line)
        DispatchQueue.main.async {
            lines.append(line); if lines.count > 200 { lines.removeFirst(lines.count - 200) }
            onChange?()
        }
    }
}
