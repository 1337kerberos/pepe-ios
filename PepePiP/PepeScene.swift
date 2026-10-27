// SceneKit scene: pepe.glb (GLTFKit2) with its skinned clips as SCNAnimationPlayers, a fixed 3/4 camera, three lights +
// ambient scaled by a brightness factor, the bubble + status line as textured planes IN the 3D frame (so they are
// visible inside the PiP card), the cigar (PROP_mesh, driven by the PROP_cigar bone whose in-hand tracks are baked into
// every clip by tools/make_pepe_glb.py) with a tip wisp, and an exhale burst from the mouth during the smoke take.
import SceneKit
import GLTFKit2
import UIKit
import simd

final class PepeScene {
    static let clearColor = UIColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1)
    static let metalClearColor = MTLClearColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1)
    static let cigarLength: Float = 0.133          // PROP_cigar: lip end at the bone origin, tip at +Y * length (clips_boss.json)
    static let exhaleTime: TimeInterval = 4.33     // jaw opens 4.33 s into the full smoke_exhale take (clips_boss.json smoke.exhale_t)

    private(set) var scene = SCNScene()
    private var players: [String: SCNAnimationPlayer] = [:]
    private var durations: [String: TimeInterval] = [:]
    private var current: String?
    private var lights: [(SCNLight, CGFloat)] = []  // light, base intensity
    private let bubbleNode = TextPlane(width: 1.25, height: 0.42, pixels: CGSize(width: 750, height: 252), font: 34, color: .black, bg: UIColor(white: 1, alpha: 0.95))
    private let statusNode = TextPlane(width: 1.5, height: 0.14, pixels: CGSize(width: 900, height: 84), font: 36, color: .white, bg: UIColor(white: 0, alpha: 0.45))
    // clips are pre-faced +Z (make_clips_boss.py), so the camera sits on the +Z side
    private var propMesh: SCNNode?
    private var cigarBone: SCNNode?
    private var tipNode: SCNNode?
    private var headNode: SCNNode?
    private var mouthInHead = simd_float3(0, 0.04, 0.12)
    private var wisp: SCNParticleSystem?
    private var cigarOn = true
    private var exhaleCount = 0

    func load(completion: @escaping (Error?) -> Void) {
        guard let url = Bundle.main.url(forResource: "pepe", withExtension: "glb") else {
            completion(NSError(domain: "pepe", code: 1, userInfo: [NSLocalizedDescriptionKey: "pepe.glb missing from the bundle"])); return
        }
        // README snippet of GLTFKit2: GLTFAsset.load(with:options:) { progress, status, asset, error, stop in ... }
        GLTFAsset.load(with: url, options: [:]) { [weak self] (_, status, maybeAsset, maybeError, _) in
            DispatchQueue.main.async {
                guard let self else { return }
                if status == .complete, let asset = maybeAsset {
                    self.build(from: asset); completion(nil)
                } else if let error = maybeError {
                    completion(error)
                } else if status == .error {
                    completion(NSError(domain: "pepe", code: 2, userInfo: [NSLocalizedDescriptionKey: "glTF load error"]))
                }
            }
        }
    }

    private func build(from asset: GLTFAsset) {
        let source = GLTFSCNSceneSource(asset: asset)
        guard let loaded = source.defaultScene else { Log.add("glb has no default scene"); return }
        scene = loaded
        scene.background.contents = PepeScene.clearColor   // a framed "window into Pepe's room"
        for anim in source.animations {
            let p = anim.animationPlayer
            p.animation.usesSceneTimeBase = false
            p.animation.blendInDuration = 0.3
            p.animation.blendOutDuration = 0.3
            p.animation.isRemovedOnCompletion = false
            durations[anim.name] = p.animation.duration
            players[anim.name] = p
        }
        Log.add("glb: \(players.count) clips: \(players.keys.sorted().joined(separator: " "))")
        addCameraAndLights()
        bubbleNode.position = SCNVector3(0, 2.02, 0.15); bubbleNode.isHidden = true; scene.rootNode.addChildNode(bubbleNode)
        statusNode.position = SCNVector3(0, 0.42, 0.9); scene.rootNode.addChildNode(statusNode)
        setupCigar()
        setStatus("ready")
    }

    private func addCameraAndLights() {
        let cam = SCNCamera(); cam.fieldOfView = 36; cam.zNear = 0.05; cam.zFar = 30
        let camNode = SCNNode(); camNode.camera = cam
        camNode.position = SCNVector3(0.85, 1.45, 2.65)              // 3/4 front view, slightly above eye level
        let target = SCNNode(); target.position = SCNVector3(0, 1.15, 0); scene.rootNode.addChildNode(target)
        let look = SCNLookAtConstraint(target: target); look.isGimbalLockEnabled = true
        camNode.constraints = [look]
        camNode.name = "pepeCamera"
        scene.rootNode.addChildNode(camNode)

        func directional(_ intensity: CGFloat, _ color: UIColor, _ euler: SCNVector3) {
            let l = SCNLight(); l.type = .directional; l.intensity = intensity; l.color = color; l.castsShadow = false
            let n = SCNNode(); n.light = l; n.eulerAngles = euler; scene.rootNode.addChildNode(n); lights.append((l, intensity))
        }
        directional(1200, UIColor(red: 1.0, green: 0.96, blue: 0.9, alpha: 1), SCNVector3(-0.6, 0.5, 0))    // key: warm, upper front-left
        directional(400, UIColor(red: 0.8, green: 0.87, blue: 1.0, alpha: 1), SCNVector3(-0.3, -1.1, 0))    // fill: cool, front-right
        directional(600, UIColor(red: 0.95, green: 0.95, blue: 1.0, alpha: 1), SCNVector3(-0.4, 2.8, 0))    // rim: from behind, over the shoulder
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 350
        let ambNode = SCNNode(); ambNode.light = amb; scene.rootNode.addChildNode(ambNode); lights.append((amb, 350))
    }

    /// Settings slider 0.5-2.0 (default 1.4): scales every light's intensity.
    func setBrightness(_ factor: Double) {
        for (l, base) in lights { l.intensity = base * CGFloat(factor) }
    }

    var cameraNode: SCNNode? { scene.rootNode.childNode(withName: "pepeCamera", recursively: false) }

    func duration(of clip: String) -> TimeInterval { durations[clip] ?? 2 }
    func has(_ clip: String) -> Bool { players[clip] != nil }

    /// Crossfade to `clip` (Fox 2 pattern: players attached to the root, play()/stop(withBlendOutDuration:)).
    func play(_ clip: String, loop: Bool, speed: Double = 1) {
        guard let p = players[clip] else { Log.add("no clip \(clip)"); return }
        if current == clip, loop { return }
        if let c = current, c != clip, let old = players[c] { old.stop(withBlendOutDuration: 0.3) }
        p.animation.repeatCount = loop ? .greatestFiniteMagnitude : 1
        p.speed = CGFloat(speed)
        if scene.rootNode.animationPlayer(forKey: clip) == nil { scene.rootNode.addAnimationPlayer(p, forKey: clip) }
        p.play()
        current = clip
        if clip == "smoke_exhale" {
            let n = exhaleCount + 1; exhaleCount = n
            DispatchQueue.main.asyncAfter(deadline: .now() + PepeScene.exhaleTime / speed) { [weak self] in
                guard let self, self.current == clip, self.exhaleCount == n else { return }
                self.exhale()
            }
        }
    }

    func setBubble(_ text: String?) {
        if let text, !text.isEmpty { bubbleNode.set(text: text); bubbleNode.isHidden = false } else { bubbleNode.isHidden = true }
    }

    func setStatus(_ text: String) { statusNode.set(text: String(text.prefix(48))) }

    // MARK: cigar + smoke
    private func setupCigar() {
        propMesh = scene.rootNode.childNode(withName: "PROP_mesh", recursively: true)
        cigarBone = scene.rootNode.childNode(withName: "PROP_cigar", recursively: true)
        headNode = scene.rootNode.childNode(withName: "Head", recursively: true)
        if let head = headNode, let lt = scene.rootNode.childNode(withName: "Lip_T_C", recursively: true),
           let lb = scene.rootNode.childNode(withName: "Lip_B_C", recursively: true) {
            let mid = (lt.simdWorldPosition + lb.simdWorldPosition) * 0.5             // rest pose: the lips' midpoint in Head space
            mouthInHead = head.simdConvertPosition(mid, from: nil)
        }
        if let cigar = cigarBone {
            let tip = SCNNode(); tip.position = SCNVector3(0, PepeScene.cigarLength, 0); cigar.addChildNode(tip); tipNode = tip
            let w = PepeScene.makeSmoke(); w.birthRate = 12; w.particleLifeSpan = 2.5; w.particleLifeSpanVariation = 0.5
            w.particleVelocity = 0.08; w.particleVelocityVariation = 0.03; w.emittingDirection = SCNVector3(0, 1, 0); w.spreadingAngle = 20
            w.particleSize = 0.02; w.acceleration = SCNVector3(0, 0.04, 0)
            w.propertyControllers = [.size: PepeScene.ramp(0.02, 0.08), .opacity: PepeScene.ramp(0.25, 0)]
            w.particleColor = UIColor(white: 0.85, alpha: 1); w.loops = true
            wisp = w
        }
        Log.add("cigar: mesh \(propMesh != nil) bone \(cigarBone != nil) head \(headNode != nil) mouth \(mouthInHead)")
        setCigar(on: cigarOn)
    }

    func setCigar(on: Bool) {
        cigarOn = on
        propMesh?.isHidden = !on
        guard let tip = tipNode, let w = wisp else { return }
        if on { if tip.particleSystems?.isEmpty ?? true { tip.addParticleSystem(w) } } else { tip.removeAllParticleSystems() }
    }

    /// Burst from the mouth, blown forward, up and off to his right (the body faces +Z; his right is -X), like the desktop "side" blow.
    func exhale() {
        guard cigarOn, let head = headNode else { return }
        let m = head.presentation.simdWorldTransform * simd_float4(mouthInHead, 1)
        let node = SCNNode(); node.simdPosition = simd_float3(m.x, m.y, m.z) + simd_float3(0, 0, 0.02)
        let dir = simd_normalize(simd_float3(-0.45, 0.35, 0.8))
        let b = PepeScene.makeSmoke(); b.birthRate = 130; b.emissionDuration = 0.6; b.loops = false
        b.particleLifeSpan = 3; b.particleLifeSpanVariation = 0.6
        b.particleVelocity = 0.35; b.particleVelocityVariation = 0.15; b.emittingDirection = SCNVector3(dir); b.spreadingAngle = 18
        b.particleSize = 0.05; b.acceleration = SCNVector3(0, 0.06, 0); b.dampingFactor = 1.5
        b.propertyControllers = [.size: PepeScene.ramp(0.05, 0.3), .opacity: PepeScene.ramp(0.5, 0)]
        b.particleColor = UIColor(white: 0.9, alpha: 1)
        node.addParticleSystem(b)
        scene.rootNode.addChildNode(node)
        Log.add("exhale at \(node.simdPosition)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { node.removeFromParentNode() }
    }

    private static let puffImage: UIImage? = Bundle.main.path(forResource: "puff", ofType: "png").flatMap { UIImage(contentsOfFile: $0) }

    private static func makeSmoke() -> SCNParticleSystem {
        let s = SCNParticleSystem()
        s.particleImage = puffImage
        s.blendMode = .alpha; s.isLightingEnabled = false; s.isAffectedByGravity = false
        s.orientationMode = .billboardScreenAligned; s.sortingMode = .distance
        s.emitterShape = SCNSphere(radius: 0.005); s.birthLocation = .volume
        s.particleAngleVariation = 180; s.particleAngularVelocityVariation = 20
        s.isLocal = false
        return s
    }

    /// value over the particle's lifetime (0 -> 1), e.g. size 0.02 -> 0.08 m or opacity 0.25 -> 0
    private static func ramp(_ a: CGFloat, _ b: CGFloat) -> SCNParticlePropertyController {
        let anim = CAKeyframeAnimation(); anim.values = [a, b]; anim.keyTimes = [0, 1]
        return SCNParticlePropertyController(animation: anim)
    }
}

/// A camera-facing plane whose texture is a rounded label drawn with UIKit; renders in SCNView, MTKView and the
/// CVPixelBuffer path alike (unlike an overlaySKScene, which is renderer-dependent).
final class TextPlane: SCNNode {
    private let pixels: CGSize
    private let font: CGFloat
    private let color: UIColor
    private let bg: UIColor
    private var last = ""

    init(width: CGFloat, height: CGFloat, pixels: CGSize, font: CGFloat, color: UIColor, bg: UIColor) {
        self.pixels = pixels; self.font = font; self.color = color; self.bg = bg
        super.init()
        let plane = SCNPlane(width: width, height: height)
        plane.cornerRadius = height * 0.3
        let m = SCNMaterial(); m.lightingModel = .constant; m.isDoubleSided = true; m.blendMode = .alpha; m.writesToDepthBuffer = false
        plane.materials = [m]
        geometry = plane
        constraints = [SCNBillboardConstraint()]
        renderingOrder = 100
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(text: String) {
        guard text != last else { return }
        last = text
        let r = UIGraphicsImageRenderer(size: pixels)
        let img = r.image { ctx in
            let rect = CGRect(origin: .zero, size: pixels)
            bg.setFill(); UIBezierPath(roundedRect: rect, cornerRadius: pixels.height * 0.3).fill()
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: font, weight: .semibold), .foregroundColor: color, .paragraphStyle: para]
            let inset = rect.insetBy(dx: 28, dy: 14)
            let h = (text as NSString).boundingRect(with: CGSize(width: inset.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: attrs, context: nil).height
            let y = inset.minY + max(0, (inset.height - min(h, inset.height)) / 2)
            (text as NSString).draw(with: CGRect(x: inset.minX, y: y, width: inset.width, height: inset.height - (y - inset.minY)), options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        }
        geometry?.firstMaterial?.diffuse.contents = img
    }
}
