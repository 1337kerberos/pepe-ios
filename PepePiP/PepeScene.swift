// SceneKit scene: pepe.glb (GLTFKit2) with its skinned clips as SCNAnimationPlayers, a fixed 3/4 camera with a slow
// drift, a backdrop preset (lounge / office / neon / plain: textured plane + floor contact shadow + per-preset lights,
// scaled by a brightness factor), the bubble + status line as textured planes IN the 3D frame (so they are visible
// inside the PiP card), the cigar (PROP_mesh, driven by the PROP_cigar bone whose in-hand tracks are baked into every
// clip by tools/make_pepe_glb.py) with a tip wisp, and an exhale burst from the mouth during the smoke take.
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
    private var keyLight = SCNLight(), fillLight = SCNLight(), rimLight = SCNLight(), ambLight = SCNLight()
    private var brightness: Double = 1.4
    private var background: Background = .lounge
    private var backdrop: SCNNode?
    private var floorNode: SCNNode?
    private var blobs: [SCNNode] = []
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
        scene.background.contents = PepeScene.clearColor
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
        addBackdrop()
        bubbleNode.position = SCNVector3(0, 2.02, 0.15); bubbleNode.isHidden = true; scene.rootNode.addChildNode(bubbleNode)
        statusNode.position = SCNVector3(0, 0.42, 0.9); scene.rootNode.addChildNode(statusNode)
        setupCigar()
        setBackground(background)
        setStatus("ready")
    }

    // MARK: camera, lights, backdrop
    private func addCameraAndLights() {
        let cam = SCNCamera(); cam.fieldOfView = 36; cam.zNear = 0.05; cam.zFar = 30
        let camNode = SCNNode(); camNode.camera = cam
        camNode.position = SCNVector3(0.85 - 0.095, 1.45, 2.65)      // 3/4 front view, slightly above eye level
        let target = SCNNode(); target.position = SCNVector3(0, 1.15, 0); scene.rootNode.addChildNode(target)
        let look = SCNLookAtConstraint(target: target); look.isGimbalLockEnabled = true
        camNode.constraints = [look]
        camNode.name = "pepeCamera"
        scene.rootNode.addChildNode(camNode)
        // slow drift: +-2 deg of yaw around the look-at target over an 8 s period, so the card never looks frozen
        let right = SCNAction.moveBy(x: 0.19, y: 0.02, z: 0, duration: 4); right.timingMode = .easeInEaseOut
        let left = SCNAction.moveBy(x: -0.19, y: -0.02, z: 0, duration: 4); left.timingMode = .easeInEaseOut
        camNode.runAction(.repeatForever(.sequence([right, left])), forKey: "drift")

        func add(_ l: SCNLight, _ type: SCNLight.LightType, _ euler: SCNVector3?) {
            l.type = type; l.castsShadow = false
            let n = SCNNode(); n.light = l; if let e = euler { n.eulerAngles = e }; scene.rootNode.addChildNode(n)
        }
        add(keyLight, .directional, SCNVector3(-0.6, 0.5, 0))     // upper front-left
        add(fillLight, .directional, SCNVector3(-0.3, -1.1, 0))   // front-right
        add(rimLight, .directional, SCNVector3(-0.4, 2.8, 0))     // from behind, over the shoulder
        add(ambLight, .ambient, nil)
    }

    private func addBackdrop() {
        let plane = SCNPlane(width: 7.5, height: 7.5)
        let m = SCNMaterial(); m.lightingModel = .constant; m.isDoubleSided = true
        plane.materials = [m]
        let n = SCNNode(geometry: plane); n.position = SCNVector3(0, 2.0, -2.6); n.renderingOrder = -10
        scene.rootNode.addChildNode(n); backdrop = n

        let floor = SCNPlane(width: 5, height: 5)
        let fm = SCNMaterial(); fm.lightingModel = .constant; fm.blendMode = .alpha; fm.writesToDepthBuffer = false
        fm.diffuse.contents = PepeScene.image("floor_shadow"); floor.materials = [fm]
        let f = SCNNode(geometry: floor); f.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0); f.position = SCNVector3(0, 0.004, 0.1); f.renderingOrder = -5
        scene.rootNode.addChildNode(f); floorNode = f

        // neon: two soft colour blobs drifting in front of the backdrop (additive glow sprites)
        for (i, color) in [UIColor(red: 0.2, green: 1.0, blue: 0.5, alpha: 1), UIColor(red: 0.7, green: 0.3, blue: 1.0, alpha: 1)].enumerated() {
            let g = SCNPlane(width: 3.2, height: 3.2)
            let gm = SCNMaterial(); gm.lightingModel = .constant; gm.blendMode = .add; gm.writesToDepthBuffer = false
            gm.diffuse.contents = PepeScene.image("glow"); gm.multiply.contents = color; g.materials = [gm]
            let b = SCNNode(geometry: g); b.position = SCNVector3(i == 0 ? -1.3 : 1.4, i == 0 ? 2.4 : 0.9, -2.4); b.renderingOrder = -8; b.opacity = 0.8
            let dx: CGFloat = i == 0 ? 0.9 : -0.8, dy: CGFloat = i == 0 ? -0.5 : 0.6, dur: TimeInterval = i == 0 ? 9 : 7
            let go = SCNAction.moveBy(x: dx, y: dy, z: 0, duration: dur); go.timingMode = .easeInEaseOut
            let back = SCNAction.moveBy(x: -dx, y: -dy, z: 0, duration: dur); back.timingMode = .easeInEaseOut
            b.runAction(.repeatForever(.sequence([go, back])))
            scene.rootNode.addChildNode(b); blobs.append(b)
        }
    }

    /// Settings > Background. Per-preset backdrop texture + light colours/intensities (the character stays readable:
    /// the key never drops below ~1100 before the brightness factor).
    func setBackground(_ bg: Background) {
        background = bg
        struct L { let key: (CGFloat, UIColor), fill: (CGFloat, UIColor), rim: (CGFloat, UIColor), amb: (CGFloat, UIColor) }
        let c = { (r: CGFloat, g: CGFloat, b: CGFloat) in UIColor(red: r, green: g, blue: b, alpha: 1) }
        let preset: L
        switch bg {
        case .lounge: preset = L(key: (1300, c(1.0, 0.88, 0.74)), fill: (350, c(0.75, 0.82, 1.0)), rim: (800, c(0.7, 0.8, 1.0)), amb: (300, c(1.0, 0.92, 0.85)))
        case .office: preset = L(key: (1150, c(0.95, 0.97, 1.0)), fill: (500, c(0.85, 0.9, 1.0)), rim: (500, c(1.0, 1.0, 1.0)), amb: (450, c(0.82, 0.87, 0.96)))
        case .neon:   preset = L(key: (1150, c(0.85, 1.0, 0.9)), fill: (450, c(0.9, 0.75, 1.0)), rim: (900, c(0.8, 0.6, 1.0)), amb: (350, c(0.9, 0.85, 1.0)))
        case .plain:  preset = L(key: (1200, c(1.0, 0.96, 0.9)), fill: (400, c(0.8, 0.87, 1.0)), rim: (600, c(0.95, 0.95, 1.0)), amb: (350, .white))
        }
        for (l, p) in [(keyLight, preset.key), (fillLight, preset.fill), (rimLight, preset.rim), (ambLight, preset.amb)] {
            l.color = p.1; l.intensity = p.0 * CGFloat(brightness)
        }
        let tex: String? = bg == .plain ? nil : "bg_\(bg.rawValue)"
        backdrop?.isHidden = tex == nil
        if let tex { backdrop?.geometry?.firstMaterial?.diffuse.contents = PepeScene.image(tex) }
        floorNode?.isHidden = bg == .plain
        blobs.forEach { $0.isHidden = bg != .neon }
        Log.add("background \(bg.rawValue) (texture \(tex.map { PepeScene.image($0) != nil ? "ok" : "MISSING" } ?? "none"))")
    }

    /// Settings slider 0.5-2.0 (default 1.4): scales every light's intensity (re-applies the current preset).
    func setBrightness(_ factor: Double) { brightness = factor; setBackground(background) }

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
            w.particleSize = 0.04; w.acceleration = SCNVector3(0, 0.04, 0)
            w.propertyControllers = [.size: PepeScene.ramp(0.04, 0.16), .opacity: PepeScene.ramp(0.4, 0)]
            w.particleColor = UIColor(red: 0.85, green: 0.85, blue: 0.9, alpha: 1); w.loops = true
            wisp = w
        }
        let puff = PepeScene.puffImage
        Log.add("cigar: mesh \(propMesh != nil) bone \(cigarBone != nil) head \(headNode != nil) mouth \(mouthInHead); puff texture \(puff.map { "\(Int($0.size.width))x\(Int($0.size.height)) scale \($0.scale)" } ?? "MISSING")")
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
        let b = PepeScene.makeSmoke(); b.birthRate = 150; b.emissionDuration = 0.8; b.loops = false     // ~120 particles
        b.particleLifeSpan = 3; b.particleLifeSpanVariation = 0.6
        b.particleVelocity = 0.35; b.particleVelocityVariation = 0.15; b.emittingDirection = SCNVector3(dir.x, dir.y, dir.z); b.spreadingAngle = 18
        b.particleSize = 0.1; b.acceleration = SCNVector3(0, 0.06, 0); b.dampingFactor = 1.5
        b.propertyControllers = [.size: PepeScene.ramp(0.1, 0.6), .opacity: PepeScene.ramp(0.7, 0)]
        b.particleColor = UIColor(red: 0.85, green: 0.85, blue: 0.9, alpha: 1)
        node.addParticleSystem(b)
        scene.rootNode.addChildNode(node)
        Log.add("exhale at \(node.simdPosition)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.8) { node.removeFromParentNode() }
    }

    static func image(_ name: String) -> UIImage? {
        Bundle.main.path(forResource: name, ofType: "png").flatMap { UIImage(contentsOfFile: $0) }
    }
    private static let puffImage: UIImage? = image("puff")

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

    /// value over the particle's lifetime (0 -> 1), e.g. size 0.1 -> 0.6 m or opacity 0.7 -> 0
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
