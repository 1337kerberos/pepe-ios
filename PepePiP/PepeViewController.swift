// UIKit host: the on-screen Pepe view (SCNView or sample-buffer view), the PiP content, mode switching, auto-PiP on
// background, and automatic fallback from the MTKView path to the sample-buffer path if PiP fails to start.
import UIKit
import SceneKit
import SwiftUI
import Combine

final class PepeViewController: UIViewController {
    let model = PepeModel.shared
    private let pip = PiPManager()
    private let feeder = PixelBufferFeeder()
    private let sourceView = UIView()                 // what the PiP card animates from (always on screen)
    private let scnView = SCNView()                   // in-app display for the video-call mode
    private let sampleView = SampleBufferView()       // in-app display + PiP content for the sample-buffer mode
    private var metalView: UIView?
    private var cancellables = Set<AnyCancellable>()
    private var activeMode: PiPMode?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        sourceView.frame = view.bounds; sourceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sourceView)
        for v in [scnView, sampleView] as [UIView] {
            v.frame = sourceView.bounds; v.autoresizingMask = [.flexibleWidth, .flexibleHeight]; v.isHidden = true; sourceView.addSubview(v)
        }
        scnView.backgroundColor = .black; scnView.antialiasingMode = .multisampling2X; scnView.preferredFramesPerSecond = 60
        scnView.rendersContinuously = true
        sampleView.displayLayer.videoGravity = .resizeAspect

        pip.onActive = { [weak self] on in
            self?.model.pipActive = on
            if on { AudioKeepAlive.shared.start() } else { AudioKeepAlive.shared.stop() }
        }
        pip.onPlayPause = { [weak self] in self?.model.requestSummary() }
        pip.onSkip = { [weak self] d in self?.model.stepCard(d) }
        pip.onFailed = { [weak self] _ in
            guard let self, self.activeMode == .videoCall else { return }
            Log.add("falling back to the sample-buffer path")
            self.model.pipMode = .sampleBuffer
        }

        model.$sceneLoaded.combineLatest(model.$pipMode, model.$autoPiP)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loaded, mode, auto in if loaded { self?.configure(mode: mode.resolved, autoStart: auto) } }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.appWentToBackground() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Log.add("foreground; PiP active=\(self?.pip.isActive ?? false)") }.store(in: &cancellables)
    }

    private func configure(mode: PiPMode, autoStart: Bool) {
        guard mode != activeMode || pip.controller == nil else { pip.controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart; return }
        activeMode = mode
        feeder.stop(); pip.teardown()
        scnView.isHidden = true; sampleView.isHidden = true
        switch mode {
        case .videoCall:
            scnView.scene = model.scene.scene
            scnView.pointOfView = model.scene.cameraNode
            scnView.isHidden = false
            if #available(iOS 18, *) {
                let mv = PepeMetalView(frame: CGRect(x: 0, y: 0, width: 540, height: 720))
                mv.scene = model.scene.scene
                metalView = mv
                pip.setupVideoCall(sourceView: sourceView, content: mv, contentSize: CGSize(width: 540, height: 720), autoStart: autoStart)
            } else {
                Log.add("MTKView PiP needs iOS 18; using the sample-buffer path")
                model.pipMode = .sampleBuffer
            }
        case .sampleBuffer, .auto:
            sampleView.isHidden = false
            feeder.start(scene: model.scene.scene, layer: sampleView.displayLayer)
            pip.setupSampleBuffer(layer: sampleView.displayLayer, autoStart: autoStart)
        }
    }

    private func appWentToBackground() {
        // canStartPictureInPictureAutomaticallyFromInline does this for us when the source view is on screen; this is
        // the belt-and-braces path (and the place to look in the log if the card never appears).
        Log.add("background; PiP possible=\(pip.isPossible) active=\(pip.isActive) mode=\(activeMode) feederFrames=\(feeder.frames)")
        let f0 = feeder.frames
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            Log.add("background +3s: feederFrames=\(self.feeder.frames) (+\(self.feeder.frames - f0)) PiP active=\(self.pip.isActive)")
        }
    }

    func startPiP() { pip.start() }
    func stopPiP() { pip.stop() }
}

struct PepeHostView: UIViewControllerRepresentable {
    @Binding var startRequest: Int
    func makeUIViewController(context: Context) -> PepeViewController { PepeViewController() }
    func updateUIViewController(_ vc: PepeViewController, context: Context) {
        if startRequest != context.coordinator.handled { context.coordinator.handled = startRequest; if startRequest > 0 { vc.startPiP() } }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var handled = 0 }
}
