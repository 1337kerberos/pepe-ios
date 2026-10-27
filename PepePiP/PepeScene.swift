// SceneKit scene: pepe.glb (GLTFKit2) with its skinned clips as SCNAnimationPlayers, a fixed 3/4 camera with a slow
// drift, a backdrop preset (lounge / office / neon / plain: textured plane + floor contact shadow + per-preset lights,
// scaled by a brightness factor), the bubble + status line as textured planes IN the 3D frame (so they are visible
// inside the PiP card), the cigar (PROP_mesh, driven by the PROP_cigar bone whose in-hand tracks are baked into every
// clip by tools/make_pepe_glb.py) with a tip wisp, and an exhale burst from the mouth during the smoke take.
import SceneKit
import GLTFKit2
import UIKit
import simd

final class PepeScene: NSObject, SCNSceneRendererDelegate {
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
    private var blobs: [(SCNNode, simd_float3, Float, Float)] = []   // node, base position, period, phase
    private var cameraNodeRef: SCNNode?
    private var bbox = (min: simd_float3(-0.4, 0, -0.3), max: simd_float3(0.4, 1.75, 0.3))
    private var camTarget = simd_float3(0, 0.83, 0)
    private var camDistance: Float = 2.8
    private var camAspect: Float = 0.75          // feed width / height
    private var pepeScale: Float = 1
    private static let camBaseYaw: Float = 18 * .pi / 180   // 3/4 view: camera on the +Z side, swung toward +X
    private static let camDriftAmp: Float = 2 * .pi / 180   // +-2 deg
    private static let camDriftPeriod: Float = 8
    private static let backdropSize: CGFloat = 9
    private static let backdropZ: Float = 2.6
    private static let backdropZOps: Float = 4.6
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
    private var ops: OpsOffice?
    private var street: StreetSet?
    private var baked: BakedSmoke?                // 0.13: the Godot six-way smoke card port (replaces the particles when ready)
    private var bakedOn = true
    private var keyNode: SCNNode?, rimNode: SCNNode?
    private var bakedActive: Bool { bakedOn && (baked?.ready ?? false) }
    private var workers: [String: Worker] = [:]
    private var showWorkers = true
    private var glbURL: URL?
    private var characterRoot: SCNNode?          // the main glb's container (for material sharing with workers)
    private var spawning = 0
    private var characterNodes: [(SCNNode, SCNVector3)] = []   // the glb's top-level nodes + their own scale (squash-and-stretch)
    private var squashT0: TimeInterval = -10
    private var squashAmp: Float = 0.16
    private var squashing = false
    private var dim: Double = 1
    static let maxWorkers = 4

    func load(completion: @escaping (Error?) -> Void) {
        AppResources.report()
        glbURL = AppResources.url("pepe.glb")
        guard let url = glbURL else {
            completion(NSError(domain: "pepe", code: 1, userInfo: [NSLocalizedDescriptionKey: "pepe.glb not found next to the app (see the log)"])); return
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
        characterNodes = scene.rootNode.childNodes.map { ($0, $0.scale) }
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
        characterRoot = scene.rootNode
        measureCharacter()
        addCameraAndLights()
        addBackdrop()
        bubbleNode.isHidden = true; scene.rootNode.addChildNode(bubbleNode)      // placed by layoutToCharacter()
        scene.rootNode.addChildNode(statusNode)
        layoutToCharacter()
        setupCigar()
        let office = OpsOffice(); office.root.isHidden = true; scene.rootNode.addChildNode(office.root); ops = office
        let st = StreetSet(); st.root.isHidden = true; scene.rootNode.addChildNode(st.root); street = st
        st.onPeriodChange = { [weak self] _ in guard let self, self.background == .street else { return }; self.setBackground(.street) }   // lights follow the clock
        setBackground(background)
        setStatus("ready")
        Log.add("triangles: character \(triangles(in: characterRoot, excluding: office.root)), office \(triangles(in: office.root, excluding: nil)), street \(st.triangleCount) (built, ~20 draw calls)")
    }

    private func triangles(in node: SCNNode?, excluding: SCNNode?) -> Int {
        guard let node else { return 0 }
        var n = 0
        node.enumerateHierarchy { child, stop in
            if child === excluding { stop.pointee = true; return }
            if let g = child.geometry { n += g.elements.reduce(0) { $0 + $1.primitiveCount } }
        }
        return n
    }

    // MARK: camera, lights, backdrop
    private func addCameraAndLights() {
        let cam = SCNCamera(); cam.fieldOfView = 36; cam.projectionDirection = .vertical; cam.zNear = 0.05; cam.zFar = 40
        let camNode = SCNNode(); camNode.camera = cam
        camNode.name = "pepeCamera"
        scene.rootNode.addChildNode(camNode); cameraNodeRef = camNode
        setFraming(aspect: camAspect, scale: pepeScale)
        placeCamera(time: 0)

        @discardableResult func add(_ l: SCNLight, _ type: SCNLight.LightType, _ euler: SCNVector3?) -> SCNNode {
            l.type = type; l.castsShadow = false
            let n = SCNNode(); n.light = l; if let e = euler { n.eulerAngles = e }; scene.rootNode.addChildNode(n)
            return n
        }
        keyNode = add(keyLight, .directional, SCNVector3(-0.6, 0.5, 0))     // upper front-left
        add(fillLight, .directional, SCNVector3(-0.3, -1.1, 0))             // front-right
        rimNode = add(rimLight, .directional, SCNVector3(-0.4, 2.8, 0))     // from behind, over the shoulder
        add(ambLight, .ambient, nil)
    }

    private func addBackdrop() {
        // sized and placed by fitBackdrop() from the camera frustum at its depth (initial size is a placeholder)
        let plane = SCNPlane(width: PepeScene.backdropSize, height: PepeScene.backdropSize)
        let m = SCNMaterial(); m.lightingModel = .constant; m.isDoubleSided = true
        m.diffuse.intensity = 1; m.multiply.contents = nil; m.diffuse.wrapS = .clamp; m.diffuse.wrapT = .clamp
        m.ambient.contents = UIColor.black; m.emission.contents = UIColor.black   // nothing but the texture
        plane.materials = [m]
        let n = SCNNode(geometry: plane); n.position = SCNVector3(0, 2.0, -PepeScene.backdropZ); n.renderingOrder = -10
        scene.rootNode.addChildNode(n); backdrop = n
        for name in ["lounge", "office", "neon"] {
            let img = EmbeddedBackdrops.image(name)
            Log.add("embedded backdrop \(name): \(img.map { "\(Int($0.size.width))x\(Int($0.size.height)) scale \($0.scale)" } ?? "DECODE FAILED (nil)")")
        }

        let floor = SCNPlane(width: 5, height: 5)
        let fm = SCNMaterial(); fm.lightingModel = .constant; fm.blendMode = .alpha; fm.writesToDepthBuffer = false
        fm.diffuse.contents = Backdrops.floorShadow; floor.materials = [fm]
        let f = SCNNode(geometry: floor); f.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0); f.position = SCNVector3(0, 0.004, 0.1); f.renderingOrder = -5
        scene.rootNode.addChildNode(f); floorNode = f

        // neon: two soft colour blobs drifting in front of the backdrop (additive glow sprites)
        for (i, color) in [UIColor(red: 0.2, green: 1.0, blue: 0.5, alpha: 1), UIColor(red: 0.7, green: 0.3, blue: 1.0, alpha: 1)].enumerated() {
            let g = SCNPlane(width: 3.2, height: 3.2)
            let gm = SCNMaterial(); gm.lightingModel = .constant; gm.blendMode = .add; gm.writesToDepthBuffer = false
            gm.diffuse.contents = Backdrops.glow; gm.multiply.contents = color; g.materials = [gm]
            let base = simd_float3(i == 0 ? -0.9 : 1.0, i == 0 ? 2.2 : 1.2, -2.4)
            let b = SCNNode(geometry: g); b.simdPosition = base; b.renderingOrder = -8; b.opacity = 0.8
            scene.rootNode.addChildNode(b); blobs.append((b, base, i == 0 ? 18 : 14, i == 0 ? 0 : 2.1))   // positions are absolute functions of time (placeCamera)
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
        case .ops:    preset = L(key: (1200, c(0.92, 0.95, 1.0)), fill: (400, c(0.8, 0.87, 1.0)), rim: (650, c(0.7, 0.8, 1.0)), amb: (260, c(0.85, 0.9, 1.0)))
        case .street:
            // by time of day; the key never drops below ~1100 so Pepe stays readable at night (the set is dimmed instead)
            switch street?.period ?? .day {
            case .dawn:  preset = L(key: (1150, c(1.0, 0.8, 0.65)), fill: (400, c(0.75, 0.8, 1.0)), rim: (750, c(1.0, 0.7, 0.6)), amb: (330, c(0.9, 0.8, 0.85)))
            case .dusk:  preset = L(key: (1150, c(1.0, 0.72, 0.48)), fill: (380, c(0.6, 0.6, 1.0)), rim: (850, c(1.0, 0.55, 0.4)), amb: (300, c(0.8, 0.7, 0.85)))
            case .night: preset = L(key: (1100, c(0.78, 0.84, 1.0)), fill: (330, c(0.6, 0.7, 1.0)), rim: (950, c(1.0, 0.8, 0.5)), amb: (250, c(0.6, 0.65, 0.9)))
            default:     preset = L(key: (1250, c(1.0, 0.96, 0.9)), fill: (450, c(0.75, 0.85, 1.0)), rim: (600, c(1.0, 1.0, 1.0)), amb: (450, c(0.85, 0.9, 1.0)))
            }
        }
        ops?.root.isHidden = bg != .ops
        street?.root.isHidden = bg != .street
        cameraNodeRef?.camera?.zFar = bg == .street ? 400 : 40       // the street's sky sits 300 m away
        for w in workers.values { w.root.isHidden = bg == .street }   // co-workers live in the office, not on the road
        fitBackdrop()   // the wall sits behind the far desks in ops, closer otherwise
        for (l, p) in [(keyLight, preset.key), (fillLight, preset.fill), (rimLight, preset.rim), (ambLight, preset.amb)] {
            l.color = p.1; l.intensity = p.0 * CGFloat(brightness * dim)
        }
        pushSmokeLights()
        // backdrop texture: the laptop-made JPEG embedded in EmbeddedBackdrops.swift (the Core Graphics versions came out
        // near-black on device); the CG drawing stays as the fallback if a decode ever fails
        var tex: UIImage? = nil; var source = "none"
        if bg != .plain && bg != .street {
            if let e = EmbeddedBackdrops.image(bg == .ops ? "office" : bg.rawValue) { tex = e; source = "embedded jpeg" }
            else { switch bg { case .lounge: tex = Backdrops.lounge; case .office: tex = Backdrops.office; default: tex = Backdrops.neon }; source = "CG fallback (embedded decode failed)" }
        }
        backdrop?.isHidden = tex == nil
        if let m = backdrop?.geometry?.firstMaterial { m.diffuse.contents = tex ?? UIColor.darkGray; m.diffuse.intensity = CGFloat(dim); m.multiply.contents = nil }
        floorNode?.isHidden = bg == .plain || bg == .street   // its square edge shows on the bright pavement
        blobs.forEach { $0.0.isHidden = bg != .neon }
        if bg == .street { source = "procedural street, \(street?.period.rawValue ?? "?")" }
        Log.add("background \(bg.rawValue): \(source)\(tex.map { " \(Int($0.size.width))x\(Int($0.size.height))" } ?? "")")
    }

    /// Settings slider 0.5-2.0 (default 1.4): scales every light's intensity (re-applies the current preset).
    func setBrightness(_ factor: Double) { brightness = factor; setBackground(background) }

    /// the baked smoke is lit by the key and the rim light: direction toward each light (world) + colour x intensity / 1000
    private func pushSmokeLights() {
        guard let baked else { return }
        var out: [(dir: simd_float3, color: simd_float3)] = []
        for (node, light) in [(keyNode, keyLight), (rimNode, rimLight)] {
            guard let node else { continue }
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            (light.color as? UIColor)?.getRed(&r, green: &g, blue: &b, alpha: &a)
            let k = Float(light.intensity / 1000)
            out.append((dir: -node.simdWorldFront, color: simd_float3(Float(r), Float(g), Float(b)) * k))
        }
        baked.setLights(out)
    }

    func setSmokeDebug(_ on: Bool) { baked?.debug = on }

    /// Settings > Look > Smoke: baked cards (default) or the 0.3 particles; brightness scales the smoke's light terms
    func setBakedSmoke(on: Bool, brightness: Float, flipV: Bool) {
        bakedOn = on
        baked?.brightness = brightness; baked?.flipV = flipV
        setCigar(on: cigarOn)
    }

    /// Reactions: face-down sleep dims every light (and the backdrop) over 1.2 s; 1 = normal.
    func setDim(_ factor: Double) {
        dim = factor
        SCNTransaction.begin(); SCNTransaction.animationDuration = 1.2
        setBackground(background)
        SCNTransaction.commit()
    }

    /// Reactions: a squash-and-stretch of the character about his feet (sy dips, then overshoots, settles in ~0.8 s;
    /// x/z keep the volume). Evaluated per frame as an absolute function of time, like the camera drift.
    func squash(amount: Float = 0.16) { squashAmp = amount; squashT0 = CACurrentMediaTime() }

    private func applySquash() {
        let t = CACurrentMediaTime() - squashT0
        if t >= 0, t < 0.9 {
            let tt = Float(t)
            let sy = 1 - squashAmp * sinf(2 * .pi * tt / 0.32) * expf(-tt / 0.2)
            let sxz = 1 / sqrtf(max(0.5, sy))
            for (n, base) in characterNodes { n.scale = SCNVector3(base.x * sxz, base.y * sy, base.z * sxz) }
            squashing = true
        } else if squashing {
            squashing = false
            for (n, base) in characterNodes { n.scale = base }
        }
    }

    /// Settings > Street time (auto = the phone clock); re-applies the lights when the street is showing.
    func setStreetTime(_ t: StreetTime) { street?.setTime(t); if background == .street { setBackground(.street) } }

    var cameraNode: SCNNode? { cameraNodeRef }

    // MARK: framing (camera from the character's bounding box; drift = yaw oscillation around the look-at target)
    private func measureCharacter() {
        var lo = simd_float3(repeating: .greatestFiniteMagnitude), hi = simd_float3(repeating: -Float.greatestFiniteMagnitude), n = 0
        for node in scene.rootNode.childNodes(passingTest: { node, _ in node.geometry != nil }) {
            let (bmin, bmax) = node.boundingBox; let w = node.simdWorldTransform
            for c in 0..<8 {
                let corner = simd_float3(c & 1 == 0 ? bmin.x : bmax.x, c & 2 == 0 ? bmin.y : bmax.y, c & 4 == 0 ? bmin.z : bmax.z)
                let p = w * simd_float4(corner, 1); lo = simd_min(lo, simd_float3(p.x, p.y, p.z)); hi = simd_max(hi, simd_float3(p.x, p.y, p.z))
            }
            n += 1
        }
        if n > 0, hi.y - lo.y > 0.3, hi.y - lo.y < 10 { bbox = (lo, hi) }
        Log.add("character bbox (\(n) meshes): min \(bbox.min) max \(bbox.max)")
    }

    /// Called with the feed aspect (w/h) whenever the card size changes, and with the "Pepe scale" slider.
    func setFraming(aspect: Float? = nil, scale: Float? = nil) {
        if let aspect { camAspect = aspect }
        if let scale { pepeScale = scale }
        let size = bbox.max - bbox.min; let centre = (bbox.max + bbox.min) * 0.5
        let tanHalf = tanf(36 * .pi / 180 / 2)
        let fill: Float = 0.85
        let dH = (size.y / fill / 2) / tanHalf                                  // full body = 85 % of the card height
        let dW = (max(size.x, size.z) / fill / 2) / (tanHalf * camAspect)       // ...and never wider than the card
        camDistance = max(dH, dW) / max(0.3, pepeScale)
        camTarget = simd_float3(centre.x, centre.y * 0.95, centre.z)
        placeCamera(time: CACurrentMediaTime())
        Log.add("camera: aspect \(camAspect) scale \(pepeScale) target \(camTarget) distance \(camDistance) position \(cameraNodeRef?.simdPosition ?? .zero)")
        fitBackdrop()
    }

    /// Size and place the backdrop plane (and the office) from the camera frustum at their depth, so the texture's
    /// spotlight/window are in view whatever the aspect, scale or character size: height = 2 * dist * tan(fov/2) * 1.15,
    /// width = height * max(aspect, 1) * 1.15, centred where the camera's line of sight meets the plane.
    private func fitBackdrop() {
        let tanHalf = tanf(36 * .pi / 180 / 2)
        let back = background == .ops ? PepeScene.backdropZOps : PepeScene.backdropZ
        let dist = camDistance * cosf(PepeScene.camBaseYaw) + back
        let h = 2 * dist * tanHalf * 1.15
        let w = h * max(camAspect, 1) * 1.15
        let cx = camTarget.x - tanf(PepeScene.camBaseYaw) * back            // the line of sight continues past the target
        let cy = camTarget.y - 0.08 * camDistance * (back / max(0.1, camDistance * cosf(PepeScene.camBaseYaw)))   // slight downward look
        if let plane = backdrop?.geometry as? SCNPlane { plane.width = CGFloat(w); plane.height = CGFloat(h) }
        backdrop?.simdPosition = simd_float3(cx, cy, camTarget.z - back)
        if let ops {
            let deskDepth: Float = 2.3
            let halfW = (camDistance * cosf(PepeScene.camBaseYaw) + deskDepth) * tanHalf * camAspect
            ops.layout(spread: min(1.5, max(0.75, halfW / 1.29)))            // 1.29 m = half-width of the 3:4 card at the desks
            ops.root.simdPosition = simd_float3(camTarget.x - tanf(PepeScene.camBaseYaw) * deskDepth, bbox.min.y, camTarget.z)
            for w in workers.values { w.root.simdPosition = ops.root.simdPosition + ops.workerSlots[w.slot] }
        }
        street?.root.simdPosition = simd_float3(0, bbox.min.y, 0)          // pavement top under his feet; he walks in place at the origin
        layoutToCharacter()
        Log.add(String(format: "backdrop: %.1fx%.1f m at (%.2f, %.2f, %.2f), %.1f m from the camera; look-at (%.2f, %.2f, %.2f)", w, h, cx, cy, camTarget.z - back, dist, camTarget.x, camTarget.y, camTarget.z))
    }

    /// Everything sized for a 1.75 m man is scaled by k = character height / 1.75 (the glb's Pepe is 1.0 m tall, found
    /// by the 0.13.2 simulator screenshots): the street set, the smoke's head radius, and the two label planes. The status
    /// line sits at his feet, the bubble is a subtitle over his legs (above the head there is only ~9 % of the card).
    private func layoutToCharacter() {
        let h = max(0.3, bbox.max.y - bbox.min.y), k = h / 1.75
        street?.setScale(k)
        baked?.headR = 0.13 * k
        statusNode.scale = SCNVector3(k, k, k)
        statusNode.position = SCNVector3((bbox.min.x + bbox.max.x) / 2, bbox.min.y + 0.07 * h, 0.3 * k)
        bubbleNode.scale = SCNVector3(k, k, k)
        bubbleNode.position = SCNVector3((bbox.min.x + bbox.max.x) / 2, bbox.min.y + 0.3 * h, 0.4 * k)
    }

    /// Absolute function of time (no accumulating actions): orbit of +-2 deg around the target, 8 s period.
    private func placeCamera(time: TimeInterval) {
        guard let cam = cameraNodeRef else { return }
        let t = Float(time)
        let yaw = PepeScene.camBaseYaw + PepeScene.camDriftAmp * sinf(2 * .pi * t / PepeScene.camDriftPeriod)
        let pos = camTarget + simd_float3(sinf(yaw) * camDistance, 0.08 * camDistance, cosf(yaw) * camDistance)
        cam.simdPosition = pos
        cam.simdLook(at: camTarget, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        for (node, base, period, phase) in blobs where !node.isHidden {
            node.simdPosition = base + simd_float3(0.9 * sinf(2 * .pi * t / period + phase), 0.5 * sinf(2 * .pi * t / (period * 0.7) + phase), 0)
        }
        if let ops, !ops.root.isHidden { ops.tick(time: time) }
    }

    // MARK: co-workers (one per agent session the brain reports; capped)
    func setWorkers(_ agents: [AgentInfo], enabled: Bool) {
        showWorkers = enabled
        let wanted = enabled ? Array(agents.prefix(PepeScene.maxWorkers)) : []
        let wantedIds = Set(wanted.map { $0.id })
        for (id, w) in workers where !wantedIds.contains(id) { remove(worker: w); workers[id] = nil }
        for a in wanted {
            if let w = workers[a.id] {
                w.lastSeen = Date()
                if w.info.state != a.state { w.info = a; w.apply(state: a.state) } else { w.info = a }
                w.setLabel()
            } else if let url = glbURL, let main = characterRoot, let slot = freeSlot() {
                let w = Worker(info: a, slot: slot); workers[a.id] = w; spawning += 1
                w.root.simdPosition = (ops.map { $0.root.simdPosition + $0.workerSlots[slot] }) ?? simd_float3(Float(slot) * 1.2 - 1.8, 0, -2.3); w.root.scale = SCNVector3(0.9, 0.9, 0.9)
                scene.rootNode.addChildNode(w.root)
                ops?.chairs[slot].isHidden = true
                w.root.isHidden = background == .street
                Log.add("agent joined: \(a.id) (\(a.state)) -> desk \(slot)")
                w.load(url: url, shareMaterialsFrom: main) { [weak self, weak w] ok in
                    guard let self, let w else { return }
                    self.spawning -= 1
                    guard ok, self.workers[w.id] === w else { return }
                    w.apply(state: w.info.state)
                    w.root.runAction(.fadeIn(duration: 0.8))
                    Log.add("triangles now: \(self.triangles(in: self.scene.rootNode, excluding: nil)) (\(self.workers.count) workers)")
                }
            }
        }
    }

    private func freeSlot() -> Int? {
        let used = Set(workers.values.map { $0.slot })
        return (0..<PepeScene.maxWorkers).first { !used.contains($0) }
    }

    private func remove(worker w: Worker) {
        Log.add("agent left: \(w.id)")
        ops?.chairs[w.slot].isHidden = false
        w.root.runAction(.sequence([.fadeOut(duration: 0.6), .removeFromParentNode()]))
    }

    /// drop workers the brain stopped mentioning (belt and braces; the brain already prunes after 10 min)
    func pruneWorkers(olderThan seconds: TimeInterval = 600) {
        for (id, w) in workers where Date().timeIntervalSince(w.lastSeen) > seconds { remove(worker: w); workers[id] = nil }
    }

    // SCNSceneRendererDelegate: every renderer (SCNView, MTKView's SCNRenderer, the pixel-buffer feeder) calls this on
    // its render thread; the camera is a pure function of time, so several renderers can share the scene safely.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        placeCamera(time: time)
        applySquash()
        if let street, !street.root.isHidden { street.tick(time: time) }
        if bakedActive, let baked, let cam = cameraNodeRef {
            baked.tick(camera: cam.presentation.simdWorldPosition, tip: cigarOn ? tipNode?.presentation.simdWorldPosition : nil)
        }
    }

    func duration(of clip: String) -> TimeInterval { durations[clip] ?? 2 }
    func has(_ clip: String) -> Bool { players[clip] != nil }

    /// Crossfade to `clip` (Fox 2 pattern: players attached to the root, play()/stop(withBlendOutDuration:)).
    /// `offset` starts the clip that many seconds in (beat sync with the desktop): looped clips wrap modulo the duration;
    /// the player is re-attached so the new timeOffset is honoured.
    func play(_ clip: String, loop: Bool, speed: Double = 1, offset: TimeInterval = 0) {
        guard let p = players[clip] else { Log.add("no clip \(clip)"); return }
        if current == clip, loop, offset == 0 { return }
        if let c = current, c != clip, let old = players[c] { old.stop(withBlendOutDuration: 0.3) }
        p.animation.repeatCount = loop ? .greatestFiniteMagnitude : 1
        p.speed = CGFloat(speed)
        let d = max(0.01, p.animation.duration)
        let off = loop ? offset.truncatingRemainder(dividingBy: d) : min(offset, d)
        if off > 0 || p.animation.timeOffset != 0 {
            if scene.rootNode.animationPlayer(forKey: clip) != nil { scene.rootNode.removeAnimation(forKey: clip) }
            p.animation.timeOffset = off
        }
        if scene.rootNode.animationPlayer(forKey: clip) == nil { scene.rootNode.addAnimationPlayer(p, forKey: clip) }
        p.play()
        current = clip
        street?.walking = clip == "walk"          // the treadmill scrolls only while the walk is the playing clip
        if clip == "smoke_exhale", off < PepeScene.exhaleTime + 0.5 {
            let n = exhaleCount + 1; exhaleCount = n
            // the jaw opens exhaleTime into the take: count from where playback starts (beat sync / test mode offsets)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, PepeScene.exhaleTime - off) / speed) { [weak self] in
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
        let bs = BakedSmoke(); scene.rootNode.addChildNode(bs.root); baked = bs
        bs.load { [weak self] ok in
            guard let self, ok else { return }
            self.pushSmokeLights()
            self.setCigar(on: self.cigarOn)            // swap the particle wisp for the baked tip card
        }
        let puff = PepeScene.puffImage
        Log.add("cigar: mesh \(propMesh != nil) bone \(cigarBone != nil) head \(headNode != nil) mouth \(mouthInHead); puff texture \(Int(puff.size.width))x\(Int(puff.size.height)) (procedural)")
        setCigar(on: cigarOn)
    }

    func setCigar(on: Bool) {
        cigarOn = on
        propMesh?.isHidden = !on
        baked?.setTip(on: on && bakedActive)
        guard let tip = tipNode, let w = wisp else { return }
        if on && !bakedActive { if tip.particleSystems?.isEmpty ?? true { tip.addParticleSystem(w) } } else { tip.removeAllParticleSystems() }
    }

    /// Burst from the mouth, blown forward, up and off to his right (the body faces +Z; his right is -X), like the desktop "side" blow.
    func exhale() {
        guard cigarOn, let head = headNode else { return }
        let m = head.presentation.simdWorldTransform * simd_float4(mouthInHead, 1)
        if bakedActive, let baked {
            // the card wants a side view: blown to his right (-X, screen left), a little up and toward the camera
            baked.beginExhale(mouth: simd_float3(m.x, m.y, m.z) + simd_float3(0, 0, 0.02), dir: simd_normalize(simd_float3(-0.75, 0.3, 0.5)))
            return
        }
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

    private static let puffImage: UIImage = Backdrops.puff

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
