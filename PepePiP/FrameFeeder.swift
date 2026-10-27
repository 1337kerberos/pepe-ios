// Two ways to get SceneKit pixels into a PiP window:
//  1. PepeMetalView: an MTKView drawn by SCNRenderer (iOS 18+ allows MTKView inside AVPictureInPictureVideoCallViewController).
//  2. PixelBufferFeeder: SCNRenderer -> IOSurface-backed CVPixelBuffer -> CMSampleBuffer -> AVSampleBufferDisplayLayer
//     (works on iOS 15+, independent of the MTKView path, and gives the system play/pause + skip buttons).
import UIKit
import SceneKit
import MetalKit
import AVFoundation
import CoreMedia
import CoreVideo

final class PepeMetalView: MTKView, MTKViewDelegate {
    private var renderer: SCNRenderer!
    var scene: SCNScene? { didSet { renderer.scene = scene; renderer.pointOfView = scene?.rootNode.childNode(withName: "pepeCamera", recursively: false) } }

    init(frame: CGRect) {
        let dev = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: dev)
        renderer = SCNRenderer(device: dev, options: nil)
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = true   // particle systems and SCNActions only advance while the renderer is playing
        colorPixelFormat = .bgra8Unorm
        depthStencilPixelFormat = .depth32Float
        preferredFramesPerSecond = 30
        // MTKView's own CADisplayLink stops when the app goes to the background, which froze the PiP card: drive the
        // draws from a GCD timer instead (the audio background mode keeps the process alive while the card is up)
        isPaused = true; enableSetNeedsDisplay = false
        delegate = self
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pepe.mtk", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in DispatchQueue.main.async { self?.draw() } }
        ticker = t; t.resume()
    }
    private var ticker: DispatchSourceTimer?
    deinit { ticker?.cancel() }
    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let scene, let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let queue = renderer.commandQueue, let cmd = queue.makeCommandBuffer() else { return }
        renderer.pointOfView = scene.rootNode.childNode(withName: "pepeCamera", recursively: false)
        pass.colorAttachments[0].clearColor = PepeScene.metalClearColor
        renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(origin: .zero, size: drawableSize), commandBuffer: cmd, passDescriptor: pass)
        cmd.present(drawable)
        cmd.commit()
    }
}

/// UIView backed by AVSampleBufferDisplayLayer (Apple's SampleBufferVideoCallView from the video-call PiP guide).
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

final class PixelBufferFeeder {
    let size: CGSize
    private let device = MTLCreateSystemDefaultDevice()!
    private let renderer: SCNRenderer
    private var pool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?
    private var depth: MTLTexture?
    private var timer: DispatchSourceTimer?
    private var formatDesc: CMVideoFormatDescription?
    private weak var layer: AVSampleBufferDisplayLayer?
    var fps: Int = 30
    private(set) var frames = 0

    init(size: CGSize = CGSize(width: 540, height: 720)) {
        self.size = size
        renderer = SCNRenderer(device: device, options: nil)
        renderer.autoenablesDefaultLighting = false
        renderer.isPlaying = true   // particle systems and SCNActions only advance while the renderer is playing
        let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                    kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                                    kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: Int(size.width), height: Int(size.height), mipmapped: false)
        dd.usage = .renderTarget; dd.storageMode = .private
        depth = device.makeTexture(descriptor: dd)
    }

    func start(scene: SCNScene, layer: AVSampleBufferDisplayLayer) {
        stop()
        renderer.scene = scene
        self.layer = layer
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "pepe.feeder", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: 1.0 / Double(fps), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t; t.resume()
        Log.add("feeder started \(Int(size.width))x\(Int(size.height)) @\(fps)")
    }

    func stop() { timer?.cancel(); timer = nil }

    private func tick() {
        guard let pool, let cache = textureCache, let layer, let scene = renderer.scene else { return }
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pixelBuffer = pb else { return }
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm, Int(size.width), Int(size.height), 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex), let queue = renderer.commandQueue, let cmd = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = tex; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = PepeScene.metalClearColor
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        renderer.pointOfView = scene.rootNode.childNode(withName: "pepeCamera", recursively: false)
        renderer.render(atTime: CACurrentMediaTime(), viewport: CGRect(origin: .zero, size: size), commandBuffer: cmd, passDescriptor: pass)
        cmd.commit()
        cmd.waitUntilCompleted()
        if cmd.status == .error { Log.add("metal cmd error: \(String(describing: cmd.error))"); return }
        guard let sb = makeSampleBuffer(pixelBuffer) else { return }
        if layer.sampleBufferRenderer.status == .failed { layer.sampleBufferRenderer.flush() }
        layer.sampleBufferRenderer.enqueue(sb)
        frames += 1
    }

    private func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDesc == nil { CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDesc) }
        guard let fd = formatDesc else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        guard let sb else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sb
    }
}
