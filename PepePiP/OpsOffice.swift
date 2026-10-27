// The "ops center" preset: a dark office behind the main Pepe (desks, flickering monitors, chairs, lamps, cool overhead
// light) and one co-worker Pepe per agent session reported by the brain (the glb loaded again per worker through
// GLTFKit2, materials shared with the main model so the 24 textures are uploaded once).
import SceneKit
import GLTFKit2
import UIKit
import simd

struct AgentInfo: Identifiable, Equatable {
    let id: String
    var state: String   // working | thinking | waiting | done | idle
    var tool: String
    var cwd: String
    var age: Double
    init?(_ d: [String: Any]) {
        guard let id = d["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        state = (d["state"] as? String) ?? "idle"; tool = (d["tool"] as? String) ?? ""; cwd = (d["cwd"] as? String) ?? ""
        age = (d["age"] as? Double) ?? 0
    }
}

/// Furniture. All primitives are SCNBox/SCNCylinder/SCNCone with few segments: ~2k triangles in total.
final class OpsOffice {
    let root = SCNNode()
    /// where a co-worker stands (behind the desk, facing +Z like the main Pepe), one per desk
    private(set) var workerSlots: [simd_float3] = []
    private var deskNodes: [SCNNode] = []
    private(set) var monitorMaterials: [(SCNMaterial, Float)] = []   // material, flicker phase
    private(set) var chairs: [SCNNode] = []
    private static let desks: [simd_float3] = [simd_float3(-1.05, 0, -2.3), simd_float3(1.05, 0, -2.3), simd_float3(-2.1, 0, -3.5), simd_float3(2.1, 0, -3.5)]

    init() {
        root.name = "ops"
        let wood = SCNMaterial(); wood.diffuse.contents = UIColor(red: 0.20, green: 0.13, blue: 0.09, alpha: 1); wood.roughness.contents = 0.8
        let metal = SCNMaterial(); metal.diffuse.contents = UIColor(white: 0.22, alpha: 1); metal.metalness.contents = 0.6; metal.roughness.contents = 0.5
        let dark = SCNMaterial(); dark.diffuse.contents = UIColor(white: 0.08, alpha: 1)
        // floor: dark, slightly glossy
        let floor = SCNPlane(width: 14, height: 14); let fm = SCNMaterial(); fm.diffuse.contents = UIColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1); fm.roughness.contents = 0.6
        floor.materials = [fm]; let fn = SCNNode(geometry: floor); fn.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0); fn.position = SCNVector3(0, -0.002, -2); fn.renderingOrder = -9
        root.addChildNode(fn)
        for (i, d) in OpsOffice.desks.enumerated() {
            let desk = SCNNode(); desk.simdPosition = d; deskNodes.append(desk)
            let top = SCNNode(geometry: SCNBox(width: 1.2, height: 0.04, length: 0.6, chamferRadius: 0.005)); top.geometry?.materials = [wood]; top.position = SCNVector3(0, 0.75, 0)
            desk.addChildNode(top)
            for (lx, lz) in [(-0.55, -0.25), (0.55, -0.25), (-0.55, 0.25), (0.55, 0.25)] {
                let leg = SCNNode(geometry: SCNBox(width: 0.05, height: 0.73, length: 0.05, chamferRadius: 0)); leg.geometry?.materials = [metal]
                leg.position = SCNVector3(lx, 0.365, lz); desk.addChildNode(leg)
            }
            // monitor: stand + thin box whose front face is an emissive bluish screen
            let stand = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 0.12)); stand.geometry?.firstMaterial = metal; (stand.geometry as? SCNCylinder)?.radialSegmentCount = 12
            stand.position = SCNVector3(-0.15, 0.83, -0.12); desk.addChildNode(stand)
            let screen = SCNMaterial(); screen.diffuse.contents = UIColor(red: 0.05, green: 0.08, blue: 0.14, alpha: 1)
            screen.emission.contents = UIColor(red: 0.35, green: 0.55, blue: 1.0, alpha: 1); screen.emission.intensity = 0.8; screen.lightingModel = .constant
            let mon = SCNBox(width: 0.5, height: 0.3, length: 0.02, chamferRadius: 0.004); mon.materials = [screen, dark, dark, dark, dark, dark]   // front face first
            let monNode = SCNNode(geometry: mon); monNode.position = SCNVector3(-0.15, 1.04, -0.12); monNode.eulerAngles = SCNVector3(0, Float.pi, 0)   // screen faces the worker (-Z side)
            desk.addChildNode(monNode); monitorMaterials.append((screen, Float(i) * 1.7))
            // desk lamp: stem + shade + a warm omni light
            let stem = SCNNode(geometry: SCNCylinder(radius: 0.012, height: 0.35)); stem.geometry?.firstMaterial = metal; (stem.geometry as? SCNCylinder)?.radialSegmentCount = 8
            stem.position = SCNVector3(0.42, 0.945, -0.1); desk.addChildNode(stem)
            let shade = SCNNode(geometry: SCNCone(topRadius: 0.03, bottomRadius: 0.09, height: 0.1)); (shade.geometry as? SCNCone)?.radialSegmentCount = 12
            let sm = SCNMaterial(); sm.diffuse.contents = UIColor(red: 0.6, green: 0.45, blue: 0.2, alpha: 1); sm.emission.contents = UIColor(red: 1.0, green: 0.75, blue: 0.4, alpha: 1); sm.emission.intensity = 0.6
            shade.geometry?.materials = [sm]; shade.position = SCNVector3(0.42, 1.12, -0.1); desk.addChildNode(shade)
            let lamp = SCNLight(); lamp.type = .omni; lamp.intensity = 160; lamp.color = UIColor(red: 1.0, green: 0.8, blue: 0.55, alpha: 1); lamp.attenuationStartDistance = 0.2; lamp.attenuationEndDistance = 2.6
            let lampNode = SCNNode(); lampNode.light = lamp; lampNode.position = SCNVector3(0.42, 1.08, -0.1); desk.addChildNode(lampNode)
            // chair behind the desk (hidden while a worker stands there)
            let chair = SCNNode(); chair.position = SCNVector3(0, 0, -0.7)
            let seat = SCNNode(geometry: SCNCylinder(radius: 0.23, height: 0.06)); (seat.geometry as? SCNCylinder)?.radialSegmentCount = 16; seat.geometry?.materials = [dark]; seat.position = SCNVector3(0, 0.46, 0)
            let post = SCNNode(geometry: SCNCylinder(radius: 0.03, height: 0.43)); (post.geometry as? SCNCylinder)?.radialSegmentCount = 8; post.geometry?.materials = [metal]; post.position = SCNVector3(0, 0.215, 0)
            let back = SCNNode(geometry: SCNBox(width: 0.44, height: 0.48, length: 0.05, chamferRadius: 0.01)); back.geometry?.materials = [dark]; back.position = SCNVector3(0, 0.75, -0.21)
            chair.addChildNode(seat); chair.addChildNode(post); chair.addChildNode(back)
            desk.addChildNode(chair); chairs.append(chair)
            root.addChildNode(desk)
        }
        layout(spread: 1)
        // cool overhead light over the desks
        let over = SCNLight(); over.type = .omni; over.intensity = 450; over.color = UIColor(red: 0.75, green: 0.85, blue: 1.0, alpha: 1); over.attenuationStartDistance = 1; over.attenuationEndDistance = 7
        let overNode = SCNNode(); overNode.light = over; overNode.position = SCNVector3(0, 3.4, -2.6); root.addChildNode(overNode)
    }

    /// Desk x positions scaled by `spread` (1 = the 3:4 card; wider cards push the desks outward, narrower pull them in)
    /// so the row stays "around" Pepe at every aspect; the root itself is placed by PepeScene at the look-at point.
    func layout(spread: Float) {
        for (i, d) in deskNodes.enumerated() { d.simdPosition = simd_float3(OpsOffice.desks[i].x * spread, 0, OpsOffice.desks[i].z) }
        workerSlots = deskNodes.map { $0.simdPosition + simd_float3(0, 0, -0.8) }
    }

    /// monitor flicker, driven from the per-frame hook (absolute in time, like the camera drift)
    func tick(time: TimeInterval) {
        let t = Float(time)
        for (m, phase) in monitorMaterials {
            let v = 0.8 + 0.12 * sinf(2 * .pi * t / 1.7 + phase) + 0.06 * sinf(2 * .pi * t / 0.23 + phase * 3)
            m.emission.intensity = CGFloat(v)
        }
    }
}

/// A co-worker: its own copy of the glb (second GLTFKit2 load) under `root`, its own animation players, a label.
final class Worker {
    let id: String
    let root = SCNNode()
    var info: AgentInfo
    var lastSeen = Date()
    var slot: Int
    private var players: [String: SCNAnimationPlayer] = [:]
    private var current: String?
    private let label = TextPlane(width: 0.8, height: 0.13, pixels: CGSize(width: 640, height: 104), font: 40, color: .white, bg: UIColor(white: 0, alpha: 0.55))

    init(info: AgentInfo, slot: Int) {
        self.id = info.id; self.info = info; self.slot = slot
        root.name = "worker:\(info.id)"; root.opacity = 0
    }

    /// Loads the glb again (GLTFKit2) and moves its nodes under `root`; `shareMaterialsFrom` = the main model's root, so
    /// geometry nodes with the same name reuse the main model's SCNMaterials (one GPU copy of the textures).
    func load(url: URL, shareMaterialsFrom main: SCNNode, completion: @escaping (Bool) -> Void) {
        GLTFAsset.load(with: url, options: [:]) { [weak self] (_, status, maybeAsset, maybeError, _) in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .complete, let asset = maybeAsset else {
                    if status == .error || maybeError != nil { Log.add("worker \(self.id): glb load failed \(String(describing: maybeError))"); completion(false) }
                    return
                }
                let source = GLTFSCNSceneSource(asset: asset)
                guard let scene = source.defaultScene else { completion(false); return }
                for child in scene.rootNode.childNodes { self.root.addChildNode(child) }
                var shared = 0
                for node in self.root.childNodes(passingTest: { n, _ in n.geometry != nil }) {
                    if let name = node.name, let m = main.childNode(withName: name, recursively: true)?.geometry?.materials, m.count == node.geometry?.materials.count {
                        node.geometry?.materials = m; shared += 1
                    }
                }
                for anim in source.animations {
                    let p = anim.animationPlayer
                    p.animation.usesSceneTimeBase = false; p.animation.blendInDuration = 0.3; p.animation.blendOutDuration = 0.3; p.animation.isRemovedOnCompletion = false
                    self.players[anim.name] = p
                }
                self.root.childNode(withName: "PROP_mesh", recursively: true)?.isHidden = true   // only the boss smokes
                self.label.position = SCNVector3(0, 2.0, 0.1); self.root.addChildNode(self.label)
                self.setLabel()
                Log.add("worker \(self.id): second glb load ok, \(self.players.count) clips, \(shared) geometries share the main materials")
                completion(true)
            }
        }
    }

    func setLabel() {
        let dir = info.cwd.split(separator: "/").last.map(String.init) ?? info.cwd
        label.set(text: dir.isEmpty ? info.id : "\(info.id) · \(dir)")
    }

    func play(_ clip: String, loop: Bool, offset: TimeInterval = 0) {
        guard let p = players[clip] else { return }
        if current == clip, loop { return }
        if let c = current, c != clip, let old = players[c] { old.stop(withBlendOutDuration: 0.3) }
        p.animation.repeatCount = loop ? .greatestFiniteMagnitude : 1
        let d = max(0.01, p.animation.duration)
        let off = loop ? offset.truncatingRemainder(dividingBy: d) : min(offset, d)
        if root.animationPlayer(forKey: clip) != nil, off > 0 { root.removeAnimation(forKey: clip) }
        p.animation.timeOffset = off
        if root.animationPlayer(forKey: clip) == nil { root.addAnimationPlayer(p, forKey: clip) }
        p.play(); current = clip
    }

    func duration(of clip: String) -> TimeInterval { players[clip]?.animation.duration ?? 2 }
    func has(_ clip: String) -> Bool { players[clip] != nil }

    /// state -> clip (desynced start so the row of workers never moves in lockstep)
    func apply(state: String) {
        let desync = Double.random(in: 0...3)
        switch state {
        case "working": play("typing", loop: true, offset: desync)
        case "thinking": play("think", loop: true, offset: desync)
        case "waiting": play("look_around", loop: true, offset: desync)
        case "done":
            play("very_happy", loop: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + duration(of: "very_happy")) { [weak self] in
                guard let self, self.info.state == "done" else { return }
                self.play("idle_standing_a", loop: true, offset: desync)
            }
        default: play(["idle_standing_a", "idle_breathing", "bored"].randomElement()!, loop: true, offset: desync)
        }
    }
}
