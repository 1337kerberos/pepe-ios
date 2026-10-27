// AVPictureInPictureController plumbing for both content sources.
//  .videoCall   : AVPictureInPictureVideoCallViewController hosting PepeMetalView (MTKView, iOS 18+). No buttons, no touch.
//  .sampleBuffer: AVSampleBufferDisplayLayer fed by PixelBufferFeeder; the system transport buttons reach us through
//                 AVPictureInPictureSampleBufferPlaybackDelegate: play/pause -> "summary", skip +/- -> next/previous card.
import AVKit
import AVFoundation
import UIKit

enum PiPMode: String, CaseIterable, Identifiable {
    case auto, videoCall, sampleBuffer
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: return "auto (MTKView on iOS 18+, else sample buffer)"; case .videoCall: return "video-call + MTKView"; case .sampleBuffer: return "sample buffer (buttons)" }
    }
    var resolved: PiPMode {
        guard self == .auto else { return self }
        // sample buffer by default: its GCD-timer feeder keeps rendering in the background (the MTKView card froze on
        // the first device test) and it gives the play/skip buttons; "video-call + MTKView" stays selectable in settings
        return .sampleBuffer
    }
}

final class PiPManager: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private(set) var controller: AVPictureInPictureController?
    private(set) var mode: PiPMode = .sampleBuffer
    let videoCallVC = AVPictureInPictureVideoCallViewController()
    var onActive: ((Bool) -> Void)?
    var onPlayPause: (() -> Void)?
    var onSkip: ((Int) -> Void)?
    var onFailed: ((Error) -> Void)?
    private var paused = false

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isPossible: Bool { controller?.isPictureInPicturePossible ?? false }

    /// `sourceView` is the on-screen view the card animates from / restores to.
    func setupVideoCall(sourceView: UIView, content: UIView, contentSize: CGSize, autoStart: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { Log.add("PiP not supported"); return }
        mode = .videoCall
        videoCallVC.preferredContentSize = contentSize
        content.frame = videoCallVC.view.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        videoCallVC.view.subviews.forEach { $0.removeFromSuperview() }
        videoCallVC.view.addSubview(content)
        let source = AVPictureInPictureController.ContentSource(activeVideoCallSourceView: sourceView, contentViewController: videoCallVC)
        install(AVPictureInPictureController(contentSource: source), autoStart: autoStart)
    }

    func setupSampleBuffer(layer: AVSampleBufferDisplayLayer, autoStart: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { Log.add("PiP not supported"); return }
        mode = .sampleBuffer
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        install(AVPictureInPictureController(contentSource: source), autoStart: autoStart)
    }

    private func install(_ c: AVPictureInPictureController, autoStart: Bool) {
        controller?.contentSource = nil
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = autoStart
        c.requiresLinearPlayback = false      // keep the skip buttons (sample-buffer mode)
        controller = c
        Log.add("PiP set up: \(mode.rawValue), autoStart \(autoStart)")
    }

    func start() {
        guard let controller else { return }
        guard controller.isPictureInPicturePossible else { Log.add("PiP not possible yet (view not on screen?)"); return }
        controller.startPictureInPicture()
    }

    func stop() { controller?.stopPictureInPicture() }
    func teardown() { controller?.contentSource = nil; controller = nil }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) { Log.add("PiP will start") }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) { Log.add("PiP started"); onActive?(true) }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { Log.add("PiP stopped"); onActive?(false) }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        Log.add("PiP failed: \(error)"); onFailed?(error)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (all six are required)
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        Log.add("PiP button: setPlaying \(playing)")
        paused = !playing
        onPlayPause?()
        // snap the button back to "playing" so every tap is a summary request
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.paused = false; c.invalidatePlaybackState() }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)   // "live": no scrubber
    }
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { paused }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        Log.add("PiP render size \(newRenderSize.width)x\(newRenderSize.height)")
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        let dir = skipInterval.seconds >= 0 ? 1 : -1
        Log.add("PiP button: skip \(dir)")
        onSkip?(dir)
        completionHandler()
    }
    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ c: AVPictureInPictureController) -> Bool { false }
}
