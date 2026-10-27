// Baked smoke (0.13): the SceneKit port of the Godot six-way smoke card (retarget_lab/smoke_stream.gd +
// retarget_lab/fx/smoke_stream.gdshader; web/smoke.js is the three.js twin). One Mantaflow exhale baked into a 12x8
// flipbook (EmbeddedSmoke "side", half-res night1 bake) is played at 30 fps on three cards fanned about the blow
// direction (+-0.42 rad, the outer two at 42 % opacity), each card's plane = blow direction x up, the bake's inflow
// (mouth_u, mouth_v) pinned to the lips; the cards stay in the world (smoke does not follow the head), the last 30 %
// dissolves by alpha erosion. The cigar tip gets the baked tip wisp (EmbeddedSmoke "tip", 75 looping frames) on a
// small Y-up billboard. Both replace the particle exhale / wisp (Settings > Look > Smoke: baked / particles).
//
// Shading (SCNShaderModifierEntryPoint.fragment, Metal): frame blend of two atlas cells, alpha = erosion smoothstep x
// atlas alpha x cone mask (side card: slim at the lips, widening along the stream, nothing behind the lips, mass toward
// the end), six-way lighting: atlas a.rgb = response to light from +X, -X, +Y of the card, b.rgb = -Y, +Z, -Z; the key
// and rim lights' directions are expressed in each card's axes on the CPU every frame (the Z pair flipped when the card
// is seen from behind, as in Godot) and passed as uniforms, plus an ambient term = mean of the six maps. Output is
// premultiplied (SceneKit's .alpha blending). Not ported: the proximity fade against geometry (needs the depth
// texture), the front card (off by default in Godot too).
import SceneKit
import UIKit
import Metal
import simd

final class BakedSmoke {
    let root = SCNNode()
    static let fps: Double = 30
    static let headR: Float = 0.13                // Pepe's head radius in metres: stream length 6.7 x, tip column 2.6 x
    static let fanAngles: [Float] = [0, 0.42, -0.42]
    static let fanFade: Float = 0.42

    private(set) var ready = false
    /// Settings > Smoke brightness (0.5-2): scales the lit and ambient terms
    var brightness: Float = 1
    /// debug: if the flipbook plays upside down / out of order on the device, the texcoord origin is bottom-left
    var flipV = false

    private var cards: [SCNNode] = []
    private var cardMats: [SCNMaterial] = []
    private var cardAxes: [(fwd: simd_float3, up: simd_float3, n: simd_float3, centre: simd_float3)] = []
    private let tipPivot = SCNNode()
    private var tipMat: SCNMaterial?
    private var tipAspect: Float = 3
    private let lock = NSLock()
    private var exT0: TimeInterval = -1
    private var exOrigin = simd_float3.zero
    private var exDir = simd_float3(0, 0, 1)
    private var exLen: TimeInterval = 3.2
    private var tipOn = false
    private var tipT0: TimeInterval = 0
    /// direction TOWARD each light (world) and its colour x intensity / 1000; set by PepeScene when the lights change
    private var lights: [(dir: simd_float3, color: simd_float3)] = []

    private static let fragment = """
    #pragma transparent
    #pragma arguments
    texture2d<float> texA;
    texture2d<float> texB;
    float frame;
    float cols;
    float rows;
    float fade;
    float erosion;
    float maxAlpha;
    float coneOn;
    float mouthU;
    float mouthV;
    float soften;
    float ambient;
    float gain;
    float flipV;
    float3 tint;
    float3 l0;
    float3 c0;
    float3 l1;
    float3 c1;
    #pragma body
    constexpr sampler smokeSmp(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 cuv = _surface.diffuseTexcoord;
    if (flipV > 0.5) cuv.y = 1.0 - cuv.y;
    float nf = cols * rows;
    float ff = clamp(frame, 0.0, nf - 1.0);
    float f0 = floor(ff);
    float f1 = min(f0 + 1.0, nf - 1.0);
    float fb = ff - f0;
    float2 cell = float2(1.0 / cols, 1.0 / rows);
    float2 uv0 = cuv * cell + float2(fmod(f0, cols) / cols, floor(f0 / cols) / rows);
    float2 uv1 = cuv * cell + float2(fmod(f1, cols) / cols, floor(f1 / cols) / rows);
    float4 sa = mix(texA.sample(smokeSmp, uv0, bias(soften)), texA.sample(smokeSmp, uv1, bias(soften)), fb);
    float4 sb = mix(texB.sample(smokeSmp, uv0, bias(soften)), texB.sample(smokeSmp, uv1, bias(soften)), fb);
    float alpha = smoothstep(erosion * 0.75, erosion * 0.75 + 0.35, sa.a) * sa.a;
    if (coneOn > 0.5) {
        float along = (cuv.x - mouthU) / max(0.001, 1.0 - mouthU);
        float r = 0.018 + 0.7 * max(along, 0.0);
        float dv = abs(cuv.y - mouthV) * 0.5;
        alpha *= 1.0 - smoothstep(r, r + 0.14 * (0.3 + along), dv);
        alpha *= along < 0.0 ? smoothstep(-0.06, 0.0, along) : 1.0;
        alpha *= mix(0.55, 1.0, smoothstep(0.0, 0.45, along));
    }
    alpha = clamp(alpha * maxAlpha * fade, 0.0, 1.0);
    float lit0 = max(l0.x, 0.0) * sa.r + max(-l0.x, 0.0) * sa.g + max(l0.y, 0.0) * sa.b
               + max(-l0.y, 0.0) * sb.r + max(l0.z, 0.0) * sb.g + max(-l0.z, 0.0) * sb.b;
    float lit1 = max(l1.x, 0.0) * sa.r + max(-l1.x, 0.0) * sa.g + max(l1.y, 0.0) * sa.b
               + max(-l1.y, 0.0) * sb.r + max(l1.z, 0.0) * sb.g + max(-l1.z, 0.0) * sb.b;
    float3 col = tint * (ambient * (sa.r + sa.g + sa.b + sb.r + sb.g + sb.b) / 6.0 + (c0 * lit0 + c1 * lit1) * gain);
    _output.color = float4(col * alpha, alpha);
    """

    /// Decode the embedded atlases off the main thread into mipmapped MTLTextures, then build the cards on main.
    /// completion(false) = keep the particles.
    func load(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = CACurrentMediaTime()
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                DispatchQueue.main.async { Log.add("baked smoke: no Metal device"); completion(false) }; return
            }
            var notes: [String] = []
            let tex = ["side_a", "side_b", "tip_a", "tip_b"].map { name -> MTLTexture? in
                guard let img = EmbeddedSmoke.image(name), let cg = img.cgImage else { notes.append("\(name): decode nil"); return nil }
                let t = BakedSmoke.texture(cg, device: device, queue: queue, note: { notes.append("\(name): \($0)") })
                return t
            }
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                Log.add("baked smoke atlases: " + notes.joined(separator: "; "))
                guard tex.allSatisfy({ $0 != nil }) else { Log.add("baked smoke: atlas upload FAILED: particles stay"); completion(false); return }
                self.build(sideA: tex[0]!, sideB: tex[1]!, tipA: tex[2]!, tipB: tex[3]!)
                Log.add(String(format: "baked smoke: ready, side %dx%d + tip %dx%d, decode + upload %.0f ms", tex[0]!.width, tex[0]!.height, tex[2]!.width, tex[2]!.height, ms))
                completion(true)
            }
        }
    }

    /// Raw RGBA bytes -> rgba8Unorm_srgb texture with mipmaps. RGB = six-way lighting (sRGB-encoded, decoded by the
    /// sampler like Godot's source_color), alpha = density (linear). Nothing may premultiply: the decoded CGImage's own
    /// bytes are copied (swizzled from BGRA / un-premultiplied only if ImageIO handed those over; logged).
    private static func texture(_ cg: CGImage, device: MTLDevice, queue: MTLCommandQueue, note: (String) -> Void) -> MTLTexture? {
        let w = cg.width, h = cg.height
        guard cg.bitsPerComponent == 8, cg.bitsPerPixel == 32, let cfData = cg.dataProvider?.data, let src = CFDataGetBytePtr(cfData) else {
            note("unsupported layout \(cg.bitsPerComponent) bpc \(cg.bitsPerPixel) bpp"); return nil
        }
        let alpha = cg.alphaInfo
        let little = cg.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        let premul = alpha == .premultipliedLast || alpha == .premultipliedFirst
        // byte offsets of R, G, B, A inside a pixel
        let (ri, gi, bi, ai): (Int, Int, Int, Int)
        switch (alphaFirst, little) {
        case (false, false): (ri, gi, bi, ai) = (0, 1, 2, 3)      // RGBA
        case (true, false):  (ri, gi, bi, ai) = (1, 2, 3, 0)      // ARGB
        case (true, true):   (ri, gi, bi, ai) = (2, 1, 0, 3)      // BGRA (little-endian ARGB)
        case (false, true):  (ri, gi, bi, ai) = (3, 2, 1, 0)      // ABGR (little-endian RGBA)
        }
        let hasAlpha = !(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let bpr = cg.bytesPerRow
        for y in 0..<h {
            let row = src + y * bpr
            for x in 0..<w {
                let p = row + x * 4, o = (y * w + x) * 4
                let a = hasAlpha ? p[ai] : 255
                if premul && a > 0 && a < 255 {
                    let k = 255.0 / Float(a)
                    out[o] = UInt8(min(255, Float(p[ri]) * k)); out[o + 1] = UInt8(min(255, Float(p[gi]) * k)); out[o + 2] = UInt8(min(255, Float(p[bi]) * k))
                } else { out[o] = p[ri]; out[o + 1] = p[gi]; out[o + 2] = p[bi] }
                out[o + 3] = a
            }
        }
        note("\(w)x\(h) alphaInfo \(alpha.rawValue)\(premul ? " (premultiplied by ImageIO: un-premultiplied, lossy)" : "")\(little ? " little-endian" : "")")
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead; d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { note("makeTexture failed"); return nil }
        out.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4) }
        if let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: t); blit.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
        }
        return t
    }

    private static let whitePixel: UIImage = {
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: fmt).image { ctx in UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2)) }
    }()

    private func material(a: MTLTexture, b: MTLTexture, cols: Int, rows: Int, side: Bool) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = BakedSmoke.whitePixel          // gives the modifier _surface.diffuseTexcoord (the card's UVs)
        m.isDoubleSided = true; m.writesToDepthBuffer = false; m.readsFromDepthBuffer = true
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: BakedSmoke.fragment]
        for (key, tex) in [("texA", a), ("texB", b)] {
            let p = SCNMaterialProperty(contents: tex)
            p.minificationFilter = .linear; p.magnificationFilter = .linear; p.mipFilter = .linear
            p.wrapS = .clamp; p.wrapT = .clamp
            m.setValue(p, forKey: key)
        }
        let meta = side ? EmbeddedSmoke.sideMeta : EmbeddedSmoke.tipMeta
        let f: [String: Float] = ["frame": 0, "cols": Float(cols), "rows": Float(rows), "fade": 1, "erosion": 0, "maxAlpha": 0.85,
                                  "coneOn": side ? 1 : 0, "mouthU": Float(meta.mouthU), "mouthV": Float(meta.mouthV),
                                  "soften": side ? 1.2 : 0.3, "ambient": side ? 0.22 : 0.3, "gain": side ? 0.3 : 0.2, "flipV": 0]
        for (k, v) in f { m.setValue(NSNumber(value: v), forKey: k) }
        m.setValue(NSValue(scnVector3: SCNVector3(0.78, 0.8, 0.86)), forKey: "tint")
        for k in ["l0", "l1"] { m.setValue(NSValue(scnVector3: SCNVector3(0, 1, 0)), forKey: k) }
        for k in ["c0", "c1"] { m.setValue(NSValue(scnVector3: SCNVector3(0, 0, 0)), forKey: k) }
        return m
    }

    private func build(sideA: MTLTexture, sideB: MTLTexture, tipA: MTLTexture, tipB: MTLTexture) {
        root.name = "bakedSmoke"
        let sm = EmbeddedSmoke.sideMeta, tm = EmbeddedSmoke.tipMeta
        for i in 0..<BakedSmoke.fanAngles.count {
            let plane = SCNPlane(width: 1, height: 0.5)          // 2:1 like the bake; local +X = along the stream
            let m = material(a: sideA, b: sideB, cols: sm.cols, rows: sm.rows, side: true)
            plane.materials = [m]
            let n = SCNNode(geometry: plane); n.isHidden = true; n.renderingOrder = 60 + i; n.castsShadow = false
            root.addChildNode(n); cards.append(n); cardMats.append(m)
        }
        exLen = Double(sm.frames) / BakedSmoke.fps
        tipAspect = Float(tm.tileH / tm.tileW)
        let tplane = SCNPlane(width: 1, height: CGFloat(tipAspect))
        let tmat = material(a: tipA, b: tipB, cols: tm.cols, rows: tm.rows, side: false)
        tplane.materials = [tmat]; tipMat = tmat
        let tcard = SCNNode(geometry: tplane); tcard.position = SCNVector3(0, tipAspect / 2, 0)   // origin at the bottom centre = the tip
        tcard.renderingOrder = 59; tcard.castsShadow = false
        tipPivot.addChildNode(tcard); tipPivot.isHidden = true
        root.addChildNode(tipPivot)
        ready = true
    }

    func setLights(_ l: [(dir: simd_float3, color: simd_float3)]) { lock.lock(); lights = l; lock.unlock() }

    func setTip(on: Bool) { lock.lock(); if on && !tipOn { tipT0 = CACurrentMediaTime() }; tipOn = on; lock.unlock() }

    /// start one exhale at the lips, blown along `dir` (world)
    func beginExhale(mouth: simd_float3, dir: simd_float3) {
        guard ready else { return }
        lock.lock(); defer { lock.unlock() }
        exOrigin = mouth; exDir = simd_normalize(dir); exT0 = CACurrentMediaTime()
        let L = 6.7 * BakedSmoke.headR
        let fwd = exDir
        var up = simd_float3(0, 1, 0)
        if abs(simd_dot(fwd, up)) > 0.9 { up = simd_float3(0, 0, 1) }
        let right = simd_normalize(simd_cross(up, fwd)); up = simd_normalize(simd_cross(fwd, right))
        let meta = EmbeddedSmoke.sideMeta
        cardAxes = []
        for (i, card) in cards.enumerated() {
            let q = simd_quatf(angle: BakedSmoke.fanAngles[i], axis: fwd)
            let u = q.act(up), n = simd_normalize(simd_cross(fwd, u))      // right-handed: x = fwd, y = up, z = normal
            // the bake's inflow (mouth_u, mouth_v; v from the top) lands on the lips
            let centre = mouth + fwd * L * Float(0.5 - meta.mouthU) + u * (L * 0.5) * Float(meta.mouthV - 0.5)
            card.simdTransform = simd_float4x4(columns: (simd_float4(fwd * L, 0), simd_float4(u * L, 0), simd_float4(n * L, 0), simd_float4(centre, 1)))
            card.isHidden = false
            cardAxes.append((fwd, u, n, centre))
        }
        Log.add(String(format: "baked exhale at (%.2f, %.2f, %.2f) dir (%.2f, %.2f, %.2f), %.1f m stream, %d cards", mouth.x, mouth.y, mouth.z, fwd.x, fwd.y, fwd.z, L, cards.count))
    }

    /// per frame from PepeScene's renderer hook (any renderer thread): flipbook clock, erosion, lights in card space,
    /// tip billboard. `camera` = the camera's world position, `tip` = the cigar tip (world) or nil.
    func tick(camera: simd_float3, tip: simd_float3?) {
        guard ready else { return }
        lock.lock(); defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let ls = Array(lights.prefix(2))
        func lightUniforms(_ m: SCNMaterial, fwd: simd_float3, up: simd_float3, n: simd_float3, flipZ: Bool) {
            for i in 0..<2 {
                var l = simd_float3(0, 1, 0), c = simd_float3.zero
                if i < ls.count { let d = ls[i].dir; l = simd_float3(simd_dot(d, fwd), simd_dot(d, up), simd_dot(d, n) * (flipZ ? -1 : 1)); c = ls[i].color }
                m.setValue(NSValue(scnVector3: SCNVector3(l.x, l.y, l.z)), forKey: "l\(i)")
                m.setValue(NSValue(scnVector3: SCNVector3(c.x * brightness, c.y * brightness, c.z * brightness)), forKey: "c\(i)")
            }
            m.setValue(NSNumber(value: flipV ? 1 : 0), forKey: "flipV")
        }
        if exT0 >= 0 {
            let t = now - exT0
            let f = t * BakedSmoke.fps
            let nf = Double(EmbeddedSmoke.sideMeta.frames)
            if f >= nf - 1 {
                exT0 = -1; cards.forEach { $0.isHidden = true }
            } else {
                let view = simd_normalize(camera - exOrigin)
                let headOn = abs(simd_dot(exDir, view))
                let wSide = 1 - BakedSmoke.smoothstep(0.6, 0.9, headOn)
                let erosion = min(1, max(0, (t / exLen - 0.7) / 0.3))
                for (i, m) in cardMats.enumerated() where i < cardAxes.count {
                    let ax = cardAxes[i]
                    m.setValue(NSNumber(value: f), forKey: "frame")
                    m.setValue(NSNumber(value: erosion), forKey: "erosion")
                    m.setValue(NSNumber(value: wSide * (i == 0 ? 1 : BakedSmoke.fanFade)), forKey: "fade")
                    m.setValue(NSNumber(value: 0.22 * brightness), forKey: "ambient")
                    lightUniforms(m, fwd: ax.fwd, up: ax.up, n: ax.n, flipZ: simd_dot(ax.n, camera - ax.centre) < 0)
                }
            }
        }
        if let tm = tipMat {
            let show = tipOn && tip != nil
            if tipPivot.isHidden == show { tipPivot.isHidden = !show }
            if show, let tip {
                let frames = Double(EmbeddedSmoke.tipMeta.frames)
                tm.setValue(NSNumber(value: ((now - tipT0) * BakedSmoke.fps).truncatingRemainder(dividingBy: frames)), forKey: "frame")
                tm.setValue(NSNumber(value: 0.3 * brightness), forKey: "ambient")
                // Y-up billboard: the column rises straight up from the tip and turns toward the camera about Y
                var nrm = camera - tip; nrm.y = 0
                nrm = simd_length(nrm) > 1e-4 ? simd_normalize(nrm) : simd_float3(0, 0, 1)
                let up = simd_float3(0, 1, 0), right = simd_normalize(simd_cross(up, nrm))
                let sz = 2.6 * BakedSmoke.headR / tipAspect
                tipPivot.simdTransform = simd_float4x4(columns: (simd_float4(right * sz, 0), simd_float4(up * sz, 0), simd_float4(nrm * sz, 0), simd_float4(tip + simd_float3(0, 0.01, 0), 1)))
                lightUniforms(tm, fwd: right, up: up, n: nrm, flipZ: false)
            }
        }
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
}
