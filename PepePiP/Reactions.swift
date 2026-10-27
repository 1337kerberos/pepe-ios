// Device reactions (0.11, research/IPHONE_INTERACTIONS.md section G): Pepe notices the phone itself.
//  (a) PiP card resized (pinch / double-tap; sample-buffer path: didTransitionToRenderSize) -> squash-and-stretch of the
//      character + a surprised one-shot (smaller card: shaking_head_no, bigger: very_happy)
//  (b) CoreMotion: shake -> stumble (standing_angry for 1 s, then back); face-down for 2 s -> he "sleeps" (bored loop,
//      lights dim); picked up again after sleeping -> wave
//  (c) battery < 20 % (not charging) or Low Power Mode -> bored loop + status "low battery"; charging begins -> very_happy
//  (d) headphones / AirPods connected -> nod
// All behind Settings > Reactions (default on); every reaction is logged ("reaction: ..."). The process stays alive under
// PiP thanks to the audio background mode, so these are expected to keep firing with the card floating (unverified on
// a device: Apple documents no background guarantee for CoreMotion; DTS says there is no motion background mode).
import Foundation
import CoreMotion
import AVFoundation
import CoreMedia
import UIKit

final class Reactions {
    unowned let model: PepeModel
    private let motion = CMMotionManager()
    private let motionQueue: OperationQueue = { let q = OperationQueue(); q.name = "pepe.motion"; q.maxConcurrentOperationCount = 1; return q }()
    private var observers: [NSObjectProtocol] = []
    private var running = false

    // motion state (motion queue only)
    private var lastShake: TimeInterval = 0
    private var faceDownSince: TimeInterval?
    private var upSince: TimeInterval?
    private var shakeSamples = 0
    // published state (main thread)
    private(set) var asleep = false
    private(set) var lowBattery = false
    private var lastRenderSize: CMVideoDimensions?
    private var lastBatteryState: UIDevice.BatteryState = .unknown

    static let shakeG = 2.0                 // |userAcceleration| in g
    static let faceDownZ = 0.85             // gravity.z (screen facing the table -> +1)
    static let faceDownHold: TimeInterval = 2
    static let pickUpHold: TimeInterval = 0.6
    static let lowLevel: Float = 0.2

    init(model: PepeModel) { self.model = model }

    func setEnabled(_ on: Bool) { on ? start() : stop() }

    func start() {
        guard !running else { return }
        running = true
        Log.add("reactions: on (motion \(motion.isDeviceMotionAvailable ? "available" : "UNAVAILABLE"))")
        // (b) motion: 20 Hz device motion (gravity + user acceleration, sensor fusion)
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 20
            motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] dm, _ in if let dm { self?.onMotion(dm) } }
        }
        // (c) battery + Low Power Mode
        UIDevice.current.isBatteryMonitoringEnabled = true
        lastBatteryState = UIDevice.current.batteryState
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.checkPower(reason: "level") })
        observers.append(nc.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.batteryStateChanged() })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in self?.checkPower(reason: "low power mode") })
        // (d) audio route: headphones in
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] n in self?.routeChanged(n) })
        checkPower(reason: "start")
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
        if asleep { asleep = false; model.director.setSleeping(false) }
        if lowBattery { lowBattery = false; model.director.setLowBattery(false) }
        Log.add("reactions: off")
    }

    // MARK: (a) PiP card resized
    /// PiPManager's didTransitionToRenderSize (sample-buffer path). The first size after PiP starts is the baseline.
    func cardResized(_ size: CMVideoDimensions) {
        defer { lastRenderSize = size }
        guard running, model.sceneLoaded, let prev = lastRenderSize, prev.width != size.width || prev.height != size.height else { return }
        let grew = Int(size.width) * Int(size.height) > Int(prev.width) * Int(prev.height)
        Log.add("reaction: card resized \(prev.width)x\(prev.height) -> \(size.width)x\(size.height) (\(grew ? "bigger: very_happy" : "smaller: shaking_head_no"))")
        model.scene.squash()
        model.director.react(grew ? .veryHappy : .shakeNo)
    }

    func pipStopped() { lastRenderSize = nil }

    // MARK: (b) motion
    private func onMotion(_ dm: CMDeviceMotion) {
        let now = CACurrentMediaTime()
        let a = dm.userAcceleration, g = dm.gravity
        let mag = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        // shake: two samples over the threshold within the debounce window (a single bump is a tap on the table)
        if mag > Reactions.shakeG { shakeSamples += 1 } else if shakeSamples > 0 { shakeSamples -= 1 }
        if shakeSamples >= 2, now - lastShake > 3 {
            lastShake = now; shakeSamples = 0
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.model.sceneLoaded else { return }
                Log.add(String(format: "reaction: shake (%.1f g) -> stumble", mag))
                self.model.scene.squash(amount: 0.1)
                self.model.director.react(.angry, hold: 1.0)            // standing_angry@0-1, then back to the base loop
            }
        }
        // face-down -> sleep; picked up -> wake + wave
        if g.z > Reactions.faceDownZ {
            upSince = nil
            if faceDownSince == nil { faceDownSince = now }
            if let t = faceDownSince, now - t > Reactions.faceDownHold {
                faceDownSince = .greatestFiniteMagnitude                    // fire once per face-down
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.running, !self.asleep else { return }
                    self.asleep = true
                    Log.add(String(format: "reaction: face-down (gravity.z %.2f) -> sleep", g.z))
                    self.model.director.setSleeping(true)
                }
            }
        } else {
            faceDownSince = nil
            if g.z < 0.3 {
                if upSince == nil { upSince = now }
                if let t = upSince, now - t > Reactions.pickUpHold {
                    upSince = .greatestFiniteMagnitude
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.running, self.asleep else { return }
                        self.asleep = false
                        Log.add(String(format: "reaction: picked up (gravity.z %.2f) -> wake + wave", g.z))
                        self.model.director.setSleeping(false)
                    }
                }
            } else { upSince = nil }
        }
    }

    // MARK: (c) power
    private func checkPower(reason: String) {
        guard running else { return }
        let d = UIDevice.current
        let level = d.batteryLevel                                         // -1 when unknown (simulator / monitoring off)
        let charging = d.batteryState == .charging || d.batteryState == .full
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        let low = lpm || (level >= 0 && level < Reactions.lowLevel && !charging)
        guard low != lowBattery else { return }
        lowBattery = low
        Log.add(String(format: "reaction: %@ (battery %.0f%%, %@, low power mode %@, via %@)", low ? "low battery -> bored" : "battery ok", max(0, level) * 100,
                       charging ? "charging" : "unplugged", lpm ? "on" : "off", reason))
        model.director.setLowBattery(low)
    }

    private func batteryStateChanged() {
        let s = UIDevice.current.batteryState
        defer { lastBatteryState = s }
        guard running else { return }
        if s == .charging, lastBatteryState == .unplugged {
            Log.add("reaction: charging -> very_happy")
            model.director.react(.veryHappy, bubble: "ahh, power")
        }
        checkPower(reason: "battery state")
    }

    // MARK: (d) headphones
    private func routeChanged(_ n: Notification) {
        guard running, let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw), reason == .newDeviceAvailable else { return }
        let headphones: [AVAudioSession.Port] = [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio]
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first(where: { headphones.contains($0.portType) }) else { return }
        Log.add("reaction: headphones (\(out.portName)) -> nod")
        model.director.react(.nod)
    }
}
