// SceneKit scene: pepe.glb (GLTFKit2) with its skinned clips as SCNAnimationPlayers, a fixed 3/4 camera, soft light,
// and the bubble + status line as textured planes IN the 3D frame (so they are visible inside the PiP card).
import SceneKit
import GLTFKit2
import UIKit

final class PepeScene {
    private(set) var scene = SCNScene()
    private var players: [String: SCNAnimationPlayer] = [:]
    private var durations: [String: TimeInterval] = [:]
    private var current: String?
    private let bubbleNode = TextPlane(width: 1.25, height: 0.42, pixels: CGSize(width: 750, height: 252), font: 34, color: .black, bg: UIColor(white: 1, alpha: 0.95))
    private let statusNode = TextPlane(width: 1.5, height: 0.14, pixels: CGSize(width: 900, height: 84), font: 36, color: .white, bg: UIColor(white: 0, alpha: 0.45))
    // clips are pre-faced +Z (make_clips_boss.py), so the camera sits on the +Z side

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
        scene.background.contents = UIColor(red: 0.09, green: 0.11, blue: 0.16, alpha: 1)   // a framed "window into Pepe's room"
        for anim in source.animations {
            let p = anim.animationPlayer
            p.animation.usesSceneTimeBase = false
            p.animation.blendInDuration = 0.3
            p.animation.blendOutDuration = 0.3
            p.animation.isRemovedOnCompletion = false
            durations[anim.name] = p.animation.duration
            players[anim.name] = p
        }
        Log.add("glb: \(players.count) clips, nodes \(scene.rootNode.childNodes.count)")
        addCameraAndLights()
        bubbleNode.position = SCNVector3(0, 2.02, 0.15); bubbleNode.isHidden = true; scene.rootNode.addChildNode(bubbleNode)
        statusNode.position = SCNVector3(0, 0.42, 0.9); scene.rootNode.addChildNode(statusNode)
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

        let key = SCNLight(); key.type = .directional; key.intensity = 900; key.color = UIColor(white: 1, alpha: 1)
        let keyNode = SCNNode(); keyNode.light = key; keyNode.eulerAngles = SCNVector3(-0.6, 0.5, 0); scene.rootNode.addChildNode(keyNode)
        let fill = SCNLight(); fill.type = .directional; fill.intensity = 350; fill.color = UIColor(red: 0.8, green: 0.85, blue: 1, alpha: 1)
        let fillNode = SCNNode(); fillNode.light = fill; fillNode.eulerAngles = SCNVector3(-0.3, -1.1, 0); scene.rootNode.addChildNode(fillNode)
        let amb = SCNLight(); amb.type = .ambient; amb.intensity = 300
        let ambNode = SCNNode(); ambNode.light = amb; scene.rootNode.addChildNode(ambNode)
    }

    var cameraNode: SCNNode? { scene.rootNode.childNode(withName: "pepeCamera", recursively: false) }

    func duration(of clip: String) -> TimeInterval { durations[clip] ?? 2 }

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
    }

    func setBubble(_ text: String?) {
        if let text, !text.isEmpty { bubbleNode.set(text: text); bubbleNode.isHidden = false } else { bubbleNode.isHidden = true }
    }

    func setStatus(_ text: String) { statusNode.set(text: String(text.prefix(48))) }
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
