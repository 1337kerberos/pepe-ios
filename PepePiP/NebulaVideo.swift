// 0.14 "nebula" background: the VFX agent's seamless 12 s loop (Assets/nebula_720.mp4, 1280x720 H.264, 24 fps, no
// audio) as a video texture on the backdrop plane. AVQueuePlayer + AVPlayerLooper (gapless loop), muted, paused while
// neither the app nor the PiP card is visible. The embedded still (EmbeddedNebula, frame 1) is on the plane until the
// first video frame arrives and stays there if the file is missing or playback fails.
//
// Two ways to get the frames onto the SceneKit material (Settings > Look > Nebula video, launch arg -nebulaVideo):
//  - output (default): AVPlayerItemVideoOutput -> CVPixelBuffer (BGRA, Metal-compatible) -> CVMetalTextureCache ->
//    MTLTexture set as diffuse.contents from the render delegate. Works in every renderer we use (SCNView, the MTKView's
//    SCNRenderer, the offscreen pixel-buffer feeder) because nothing depends on SceneKit's own AVPlayer support.
//  - player: diffuse.contents = the AVPlayer (SceneKit's built-in video material).
//  - still: never start the video (the fallback look).
import AVFoundation
import CoreVideo
import Metal
import SceneKit
import UIKit

final class NebulaVideo {
    enum Mode: String, CaseIterable, Identifiable {
        case output, player, still
        var id: String { rawValue }
        var label: String {
            switch self { case .output: return "video output -> Metal texture"; case .player: return "AVPlayer as material"; case .still: return "still only" }
        }
    }

    static let fileName = "nebula_720.mp4"
    static let videoAspect: CGFloat = 1280.0 / 720.0
    static let stillImage: UIImage? = EmbeddedNebula.still()

    private(set) var mode: Mode = .output
    private weak var material: SCNMaterial?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var outputs: [ObjectIdentifier: AVPlayerItemVideoOutput] = [:]   // one per looping replica item
    private var itemObs: NSKeyValueObservation?
    private var statusObs: [NSKeyValueObservation] = []
    private var cache: CVMetalTextureCache?
    private var lastTexture: MTLTexture?
    private var inFlight: [CVMetalTexture] = []      // keep the last few textures alive while the GPU may still read them
    private let lock = NSLock()
    private var active = false                       // the nebula preset is showing
    private var appVisible = UIApplication.shared.applicationState != .background
    private var pipVisible = false
    private var showingVideo = false                 // false = the still is on the plane
    private var frames = 0
    private var startedAt: CFTimeInterval = 0
    private var failed = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.appVisible = false; self?.updatePlayback("app background") })
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.appVisible = true; self?.updatePlayback("app foreground") })
        Log.add("nebula: still \(NebulaVideo.stillImage.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "DECODE FAILED")")
    }
    deinit { for o in observers { NotificationCenter.default.removeObserver(o) } }

    /// PepeModel.pipActive -> here: the card counts as visible even with the app in the background.
    func setPiPVisible(_ on: Bool) { pipVisible = on; updatePlayback(on ? "PiP on" : "PiP off") }

    /// setBackground(.nebula) / any other preset. The material is the backdrop plane's.
    func activate(_ on: Bool, material m: SCNMaterial?, mode newMode: Mode) {
        lock.lock()
        let modeChanged = newMode != mode
        mode = newMode; material = m; active = on
        lock.unlock()
        if modeChanged { teardown() }
        guard on, let m else { updatePlayback("preset off"); return }
        // put back what the plane showed last (another preset may have replaced the contents meanwhile)
        if showingVideo, mode == .player, let player { m.diffuse.contents = player }
        else if showingVideo, mode == .output, let last = lastTexture { m.diffuse.contents = last }
        else { m.diffuse.contents = NebulaVideo.stillImage ?? UIColor(red: 0.08, green: 0.05, blue: 0.14, alpha: 1); showingVideo = false }
        if mode != .still, player == nil, !failed { start() }
        updatePlayback("preset on")
    }

    /// The plane's width/height: crop the 16:9 video (and the 16:9 still) to it, centred, never stretched.
    func cropTransform(planeAspect a: CGFloat) -> SCNMatrix4 {
        let v = NebulaVideo.videoAspect
        if a < v {
            let sx = Float(a / v)
            return SCNMatrix4Mult(SCNMatrix4MakeScale(sx, 1, 1), SCNMatrix4MakeTranslation((1 - sx) / 2, 0, 0))
        }
        let sy = Float(v / a)
        return SCNMatrix4Mult(SCNMatrix4MakeScale(1, sy, 1), SCNMatrix4MakeTranslation(0, (1 - sy) / 2, 0))
    }

    private func start() {
        guard let url = AppResources.url(NebulaVideo.fileName) else {
            failed = true; Log.add("nebula: \(NebulaVideo.fileName) MISSING, keeping the still"); return
        }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let p = AVQueuePlayer()
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible    // keep looping behind the PiP card
        p.automaticallyWaitsToMinimizeStalling = false
        let l = AVPlayerLooper(player: p, templateItem: item)
        player = p; looper = l; startedAt = CACurrentMediaTime(); frames = 0
        for it in l.loopingPlayerItems { attach(it) }
        itemObs = p.observe(\.currentItem, options: [.initial, .new]) { [weak self] p, _ in
            DispatchQueue.main.async { if let it = p.currentItem { self?.attach(it) } }
        }
        Log.add("nebula: \(mode.rawValue) mode, \(url.lastPathComponent) (\(l.loopingPlayerItems.count) looping items)")
        // watchdog: no frame after 6 s -> say so (the still stays up)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.player === p, !self.showingVideo, self.active else { return }
            Log.add("nebula: no video frame after 6 s (status \(p.currentItem?.status.rawValue ?? -1), error \(p.currentItem?.error?.localizedDescription ?? "none")); still stays")
        }
    }

    private func attach(_ item: AVPlayerItem) {
        let key = ObjectIdentifier(item)
        if statusObs.count < 16 {
            statusObs.append(item.observe(\.status, options: [.new]) { [weak self] it, _ in
                DispatchQueue.main.async { self?.itemStatus(it) }
            })
        }
        guard mode == .output else { return }
        lock.lock(); defer { lock.unlock() }
        guard outputs[key] == nil else { return }
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        out.suppressesPlayerRendering = true
        item.add(out)
        outputs[key] = out
    }

    private func itemStatus(_ it: AVPlayerItem) {
        switch it.status {
        case .failed:
            if !failed { failed = true; Log.add("nebula: playback FAILED (\(it.error?.localizedDescription ?? "?")), keeping the still") }
        case .readyToPlay:
            if mode == .player, !showingVideo, active, let player, let m = material {
                showingVideo = true; m.diffuse.contents = player
                Log.add(String(format: "nebula: AVPlayer on the material %.2fs after start", CACurrentMediaTime() - startedAt))
            }
        default: break
        }
    }

    private func updatePlayback(_ why: String) {
        guard let player else { return }
        let want = active && (appVisible || pipVisible) && !failed
        if want, player.rate == 0 { player.play(); Log.add("nebula: play (\(why))") }
        else if !want, player.rate != 0 { player.pause(); Log.add("nebula: pause (\(why))") }
    }

    private func teardown() {
        player?.pause(); looper?.disableLooping(); itemObs = nil; statusObs = []
        lock.lock(); outputs = [:]; inFlight = []; lastTexture = nil; lock.unlock()
        player = nil; looper = nil; showingVideo = false; failed = false
    }

    /// Render delegate (any renderer's thread): copy the newest decoded frame into a Metal texture on the material.
    func tick(device: MTLDevice?) {
        lock.lock(); defer { lock.unlock() }
        guard active, mode == .output, let m = material, let item = player?.currentItem, let out = outputs[ObjectIdentifier(item)] else { return }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t), let pb = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        if cache == nil, let dev = device ?? MTLCreateSystemDefaultDevice() {
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
        }
        guard let cache else { return }
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm_srgb, w, h, 0, &cvTex)
        guard r == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            if frames == 0 { Log.add("nebula: texture from pixel buffer failed (\(r))") }
            return
        }
        inFlight.append(cvTex); if inFlight.count > 4 { inFlight.removeFirst() }
        m.diffuse.contents = tex; lastTexture = tex
        frames += 1
        if !showingVideo {
            showingVideo = true
            let dt = CACurrentMediaTime() - startedAt
            DispatchQueue.main.async { Log.add("nebula: first video frame \(w)x\(h) on the plane " + String(format: "%.2fs after start", dt)) }
        }
        if frames == 240 || frames == 2400 { let n = frames; DispatchQueue.main.async { Log.add("nebula: \(n) video frames shown") } }
        if frames % 120 == 0 { CVMetalTextureCacheFlush(cache, 0) }
    }
}
