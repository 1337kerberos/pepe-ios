// The "street" preset (0.10): a procedural treadmill set under Pepe. He walks in place (the in-place `walk` clip, see
// tools/make_pepe_glb.py IN_PLACE) and the set scrolls past him at the clip's stride speed, so he reads as walking toward
// the camera down a city street: pavement with joints, a road with dashes and the odd car, two rows of buildings with
// window grids (lit at night), lamp posts, a far skyline and a sky gradient by time of day (dawn/day/dusk/night from the
// clock, or forced in Settings). Everything is built from merged custom geometry (vertex colours, a handful of shared
// materials, ~20 draw calls, a few thousand triangles); no textures, no files.
//
// Local frame of `root`: street axis = Z (Pepe at the origin facing +Z = his walking direction), x across (road on -X),
// y up (pavement top at 0). Walking moves the ground toward -Z (away from the camera, behind him), which is the
// physically right direction for someone walking toward the viewer. `root` is turned by `streetYaw` so the street's
// vanishing point sits inside the 3/4 camera's frame instead of just past its right edge (the camera looks 18 deg off
// the walking axis); the 10 deg mismatch between his stride and the ground is invisible at card size.
import SceneKit
import UIKit
import simd

enum StreetTime: String, CaseIterable, Identifiable {
    case auto, dawn, day, dusk, night
    var id: String { rawValue }
    var label: String { self == .auto ? "auto (phone clock)" : rawValue }
    /// dawn 05-08, day 08-17, dusk 17-20, night 20-05 (local time)
    static func fromClock(_ date: Date = Date()) -> StreetTime {
        let h = Calendar.current.component(.hour, from: date)
        switch h { case 5..<8: return .dawn; case 8..<17: return .day; case 17..<20: return .dusk; default: return .night }
    }
}

/// Collects quads into one geometry with several elements (one per material): positions, normals, vertex colours.
final class MeshBuilder {
    private var positions: [SCNVector3] = []
    private var normals: [SCNVector3] = []
    private var colors: [SIMD4<Float>] = []
    private var indices: [[UInt32]]
    init(materials: Int) { indices = Array(repeating: [], count: materials) }
    var triangles: Int { indices.reduce(0) { $0 + $1.count / 3 } }

    /// a, b, c, d counter-clockwise as seen from the front side
    func quad(_ a: simd_float3, _ b: simd_float3, _ c: simd_float3, _ d: simd_float3, color: simd_float3, mat: Int) {
        let n = simd_normalize(simd_cross(b - a, c - a))
        let base = UInt32(positions.count)
        for p in [a, b, c, d] { positions.append(SCNVector3(p.x, p.y, p.z)); normals.append(SCNVector3(n.x, n.y, n.z)); colors.append(SIMD4<Float>(color, 1)) }
        indices[mat] += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    /// box faces from `faces` ("+x", "-x", "+z", "-z", "+y"); the bottom is never visible
    func box(_ lo: simd_float3, _ hi: simd_float3, color: simd_float3, mat: Int, faces: Set<String> = ["+x", "-x", "+z", "-z", "+y"]) {
        if faces.contains("+x") { quad(simd_float3(hi.x, lo.y, hi.z), simd_float3(hi.x, lo.y, lo.z), simd_float3(hi.x, hi.y, lo.z), simd_float3(hi.x, hi.y, hi.z), color: color, mat: mat) }
        if faces.contains("-x") { quad(simd_float3(lo.x, lo.y, lo.z), simd_float3(lo.x, lo.y, hi.z), simd_float3(lo.x, hi.y, hi.z), simd_float3(lo.x, hi.y, lo.z), color: color, mat: mat) }
        if faces.contains("+z") { quad(simd_float3(lo.x, lo.y, hi.z), simd_float3(hi.x, lo.y, hi.z), simd_float3(hi.x, hi.y, hi.z), simd_float3(lo.x, hi.y, hi.z), color: color, mat: mat) }
        if faces.contains("-z") { quad(simd_float3(hi.x, lo.y, lo.z), simd_float3(lo.x, lo.y, lo.z), simd_float3(lo.x, hi.y, lo.z), simd_float3(hi.x, hi.y, lo.z), color: color, mat: mat) }
        if faces.contains("+y") { quad(simd_float3(lo.x, hi.y, hi.z), simd_float3(hi.x, hi.y, hi.z), simd_float3(hi.x, hi.y, lo.z), simd_float3(lo.x, hi.y, lo.z), color: color, mat: mat) }
    }

    /// horizontal quad at height y (normal +Y)
    func floor(x0: Float, x1: Float, z0: Float, z1: Float, y: Float, color: simd_float3, mat: Int) {
        quad(simd_float3(x0, y, z1), simd_float3(x1, y, z1), simd_float3(x1, y, z0), simd_float3(x0, y, z0), color: color, mat: mat)
    }

    func geometry(materials: [SCNMaterial]) -> SCNGeometry {
        let v = SCNGeometrySource(vertices: positions)
        let n = SCNGeometrySource(normals: normals)
        let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let c = SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                  componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                  dataStride: MemoryLayout<SIMD4<Float>>.stride)
        var elements: [SCNGeometryElement] = [], mats: [SCNMaterial] = []
        for (i, idx) in indices.enumerated() where !idx.isEmpty {
            elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles)); mats.append(materials[i])
        }
        let g = SCNGeometry(sources: [v, n, c], elements: elements)
        g.materials = mats
        return g
    }
}

/// Deterministic random numbers (the same street every launch; tiles differ by seed).
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(state % 1_000_000) / 1_000_000
    }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
}

final class StreetSet {
    let root = SCNNode()
    static let streetYaw: Float = 10 * .pi / 180
    /// metres per second of the in-place walk clip (make_pepe_glb.py prints it: 1.809 m of Hips travel in 1.70 s)
    static let walkSpeed: Float = 1.0643
    static let tileLength: Float = 36           // joints (1.5 m), dashes (6 m) and lamps (12 m) all divide it
    static let tileCount = 4                    // coverage: from behind the camera to ~110 m down the street

    /// set on the main thread by PepeScene.play (true while the current clip is the walk), read on the render thread
    var walking = false
    var timeOverride: StreetTime = .auto
    /// the set is modelled for a 1.75 m man; PepeScene scales it to the character (k = height / 1.75). The ground must
    /// still move at the clip's WORLD speed, so in the set's own (scaled) units it moves walkSpeed / k.
    private var scale: Float = 1
    func setScale(_ k: Float) { lock.lock(); scale = max(0.1, k); lock.unlock(); root.scale = SCNVector3(k, k, k) }
    var onPeriodChange: ((StreetTime) -> Void)?
    private(set) var period: StreetTime = StreetTime.fromClock()

    private var tiles: [SCNNode] = []
    private let skyNode = SCNNode()
    private let skylineMat = SCNMaterial()
    private let wallMat = SCNMaterial(), litMat = SCNMaterial(), darkMat = SCNMaterial(), lampMat = SCNMaterial(), shopMat = SCNMaterial()
    private var cars: [Car] = []
    private let lock = NSLock()
    private var lastTime: TimeInterval = 0
    private var speed: Float = 0                // current ground speed (eased toward walkSpeed or 0)
    private var travelled: Float = 0            // metres, kept modulo tileLength
    private var nextCarAt: TimeInterval = 0
    private var nextPeriodCheck: TimeInterval = 0
    private(set) var triangleCount = 0

    final class Car {
        let node = SCNNode()
        let body = SCNMaterial()
        var active = false
        var z: Float = 0
        var dir: Float = 1                      // +1 toward the camera (headlights), -1 away (tail lights)
        var v: Float = 10
    }

    init() {
        root.name = "street"
        root.eulerAngles = SCNVector3(0, StreetSet.streetYaw, 0)
        wallMat.lightingModel = .lambert
        wallMat.diffuse.contents = UIColor.white            // the vertex colours carry the albedo
        for m in [litMat, darkMat, lampMat, shopMat, skylineMat] { m.lightingModel = .constant }
        var tris = 0
        for k in 0..<StreetSet.tileCount {
            // three distinct tile layouts repeat (k % 3) so the street never visibly loops within the visible range
            let (geo, n) = StreetSet.makeTile(seed: UInt64(k % 3 + 1), materials: [wallMat, litMat, darkMat, lampMat, shopMat])
            let t = SCNNode(geometry: geo); t.name = "street.tile\(k)"
            root.addChildNode(t); tiles.append(t); tris += n
        }
        let (skyline, n2) = StreetSet.makeSkyline(material: skylineMat)
        let sl = SCNNode(geometry: skyline); sl.renderingOrder = -9; root.addChildNode(sl); tris += n2
        skyNode.renderingOrder = -10; root.addChildNode(skyNode)
        for i in 0..<3 { let c = StreetSet.makeCar(seed: UInt64(i + 11)); c.node.isHidden = true; root.addChildNode(c.node); cars.append(c); tris += 64 }
        triangleCount = tris + 8
        layoutTiles()
        applyPeriod(StreetTime.fromClock())
    }

    // MARK: per frame (any renderer's thread; idempotent across renderers: only a later timestamp advances the set)
    func tick(time: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if lastTime == 0 || time - lastTime > 1 { lastTime = time; nextCarAt = time + 2; return }   // first frame / after a stall: no jump
        let dt = Float(time - lastTime)
        guard dt > 0 else { return }
        lastTime = time
        let target: Float = walking ? StreetSet.walkSpeed / scale : 0
        speed += (target - speed) * min(1, dt * 5)                   // ~0.2 s ease, close to the 0.3 s clip blend
        if abs(speed) < 0.001 { speed = 0 }
        travelled = (travelled + speed * dt).truncatingRemainder(dividingBy: StreetSet.tileLength)
        layoutTiles()
        for c in cars where c.active {
            c.z += (c.dir * c.v - speed) * dt
            if c.z > 12 || c.z < -125 { c.active = false; c.node.isHidden = true } else { c.node.simdPosition.z = c.z }
        }
        if time >= nextCarAt { spawnCar(); nextCarAt = time + Double.random(in: 6...12) }
        if time >= nextPeriodCheck {
            nextPeriodCheck = time + 20
            let p = timeOverride == .auto ? StreetTime.fromClock() : timeOverride
            if p != period { applyPeriod(p); let cb = onPeriodChange; DispatchQueue.main.async { cb?(p) } }
        }
    }

    /// Settings > Street time: forces a period (auto = the clock); applied immediately.
    func setTime(_ t: StreetTime) {
        lock.lock(); timeOverride = t; nextPeriodCheck = 0; lock.unlock()
        let p = t == .auto ? StreetTime.fromClock() : t
        if p != period { applyPeriod(p) }
    }

    private func layoutTiles() {
        // tile k covers local z in [origin - L, origin]; tile 0 starts behind the camera
        let L = StreetSet.tileLength
        for (k, t) in tiles.enumerated() { t.simdPosition = simd_float3(0, 0, L * Float(1 - k) - travelled) }
    }

    private func spawnCar() {
        guard let c = cars.first(where: { !$0.active }) else { return }
        c.dir = Bool.random() ? 1 : -1
        c.v = Float.random(in: 8...13)
        c.z = c.dir > 0 ? -120 : 10
        c.body.diffuse.contents = [UIColor(red: 0.62, green: 0.08, blue: 0.08, alpha: 1), UIColor(red: 0.1, green: 0.22, blue: 0.5, alpha: 1),
                                   UIColor(white: 0.85, alpha: 1), UIColor(white: 0.12, alpha: 1), UIColor(red: 0.85, green: 0.62, blue: 0.1, alpha: 1)].randomElement()!
        c.node.simdPosition = simd_float3(c.dir > 0 ? -3.6 : -6.4, -0.15, c.z)      // toward-camera lane nearer the kerb
        c.node.simdEulerAngles = simd_float3(0, c.dir > 0 ? 0 : .pi, 0)            // the car's front is its local +Z
        c.node.isHidden = false; c.active = true
    }

    // MARK: time of day
    private func applyPeriod(_ p: StreetTime) {
        period = p
        let c = { (r: CGFloat, g: CGFloat, b: CGFloat) in UIColor(red: r, green: g, blue: b, alpha: 1) }
        let sky: [simd_float3]            // zenith, upper, horizon (bottom repeats the horizon)
        let wallDim: CGFloat, lit: UIColor, dark: UIColor, lamp: UIColor, shop: UIColor, skyline: UIColor
        switch p {
        case .dawn:
            sky = [simd_float3(0.28, 0.36, 0.62), simd_float3(0.78, 0.62, 0.66), simd_float3(1.0, 0.72, 0.5)]
            wallDim = 0.8; lit = c(1.0, 0.82, 0.55); dark = c(0.2, 0.22, 0.3); lamp = c(1.0, 0.85, 0.6); shop = c(0.75, 0.62, 0.5); skyline = c(0.55, 0.48, 0.55)
        case .day, .auto:
            sky = [simd_float3(0.25, 0.48, 0.85), simd_float3(0.5, 0.7, 0.95), simd_float3(0.82, 0.88, 0.95)]
            wallDim = 1.0; lit = c(0.3, 0.38, 0.48); dark = c(0.24, 0.3, 0.4); lamp = c(0.6, 0.6, 0.58); shop = c(0.4, 0.48, 0.56); skyline = c(0.62, 0.7, 0.8)
        case .dusk:
            sky = [simd_float3(0.16, 0.14, 0.38), simd_float3(0.72, 0.36, 0.42), simd_float3(1.0, 0.55, 0.28)]
            wallDim = 0.62; lit = c(0.85, 0.68, 0.42); dark = c(0.12, 0.12, 0.2); lamp = c(1.0, 0.82, 0.5); shop = c(0.6, 0.46, 0.32); skyline = c(0.3, 0.22, 0.34)
        case .night:
            sky = [simd_float3(0.01, 0.02, 0.06), simd_float3(0.04, 0.06, 0.16), simd_float3(0.12, 0.13, 0.25)]
            wallDim = 0.4; lit = c(0.85, 0.7, 0.45); dark = c(0.05, 0.06, 0.1); lamp = c(1.0, 0.85, 0.6); shop = c(0.55, 0.42, 0.3); skyline = c(0.06, 0.07, 0.13)
        }
        wallMat.multiply.contents = UIColor(white: wallDim, alpha: 1)    // after lighting: the walls follow the sky, Pepe does not
        litMat.diffuse.contents = lit; darkMat.diffuse.contents = dark; lampMat.diffuse.contents = lamp; shopMat.diffuse.contents = shop
        skylineMat.diffuse.contents = skyline
        let night = p == .night || p == .dusk
        for car in cars { car.node.childNodes.filter { $0.name == "lamp" }.forEach { $0.geometry?.firstMaterial?.diffuse.intensity = night ? 1 : 0.55 } }
        skyNode.geometry = StreetSet.makeSky(sky)
        Log.add("street: \(p.rawValue)\(timeOverride == .auto ? " (clock)" : " (forced)")")
    }

    // MARK: geometry
    private static func makeSky(_ c: [simd_float3]) -> SCNGeometry {
        // a 900 x 400 m vertex-coloured backdrop 300 m down the street: rows at y = -60, 0 (horizon), 45, 220
        let rows: [(Float, simd_float3)] = [(-60, c[2]), (0, c[2]), (45, c[1]), (220, c[0])]
        let z: Float = -300, x0: Float = -450, x1: Float = 450
        let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = UIColor.white; m.isDoubleSided = true
        // quads per band, colours interpolated by the rasteriser (per-vertex)
        var geo = MeshBuilderBands()
        for i in 0..<(rows.count - 1) {
            geo.band(x0: x0, x1: x1, z: z, y0: rows[i].0, y1: rows[i + 1].0, c0: rows[i].1, c1: rows[i + 1].1)
        }
        return geo.geometry(material: m)
    }

    private static func makeSkyline(material: SCNMaterial) -> (SCNGeometry, Int) {
        var r = SeededRandom(99)
        let b = MeshBuilder(materials: 1)
        var x: Float = -260
        while x < 120 {
            let w = r.range(8, 26), h = r.range(18, 75), z = -r.range(170, 200)
            b.box(simd_float3(x, -1, z - 10), simd_float3(x + w, h, z), color: simd_float3(1, 1, 1), mat: 0, faces: ["+z"])
            x += w + r.range(-2, 4)
        }
        return (b.geometry(materials: [material]), b.triangles)
    }

    /// One 36 m stretch of street (local z from -36 to 0): ground, joints, kerbs, road dashes, lamp posts, two building rows.
    private static func makeTile(seed: UInt64, materials: [SCNMaterial]) -> (SCNGeometry, Int) {
        enum M { static let wall = 0, lit = 1, dark = 2, lamp = 3, shop = 4 }
        var r = SeededRandom(seed)
        let b = MeshBuilder(materials: materials.count)
        let L = tileLength, z0: Float = -L, z1: Float = 0
        let concrete = simd_float3(0.3, 0.3, 0.3), joint = simd_float3(0.19, 0.19, 0.2), asphalt = simd_float3(0.12, 0.12, 0.14)   // the key is strong: keep the ground mid-grey
        let kerb = simd_float3(0.55, 0.55, 0.53), paint = simd_float3(0.85, 0.85, 0.8)
        // ground: near pavement (Pepe's, x -1.95..2.6), kerb, road (y -0.15, x -8.2..-1.95), far kerb, far pavement (x -10..-8.2)
        b.floor(x0: -1.8, x1: 2.6, z0: z0, z1: z1, y: 0, color: concrete, mat: M.wall)
        b.floor(x0: -1.95, x1: -1.8, z0: z0, z1: z1, y: 0, color: kerb, mat: M.wall)
        b.quad(simd_float3(-1.95, -0.15, z0), simd_float3(-1.95, -0.15, z1), simd_float3(-1.95, 0, z1), simd_float3(-1.95, 0, z0), color: kerb * 0.8, mat: M.wall)   // faces -X (the road)
        b.floor(x0: -8.2, x1: -1.95, z0: z0, z1: z1, y: -0.15, color: asphalt, mat: M.wall)
        b.quad(simd_float3(-8.2, -0.15, z1), simd_float3(-8.2, -0.15, z0), simd_float3(-8.2, 0, z0), simd_float3(-8.2, 0, z1), color: kerb * 0.8, mat: M.wall)    // faces +X
        b.floor(x0: -10, x1: -8.2, z0: z0, z1: z1, y: 0, color: concrete * 0.95, mat: M.wall)
        var z = z0
        while z < z1 - 0.01 {                                                     // pavement joints every 1.5 m (both pavements)
            b.floor(x0: -1.8, x1: 2.6, z0: z, z1: z + 0.05, y: 0.003, color: joint, mat: M.wall)
            b.floor(x0: -10, x1: -8.2, z0: z, z1: z + 0.05, y: 0.003, color: joint, mat: M.wall)
            z += 1.5
        }
        z = z0
        while z < z1 - 0.01 { b.floor(x0: -5.16, x1: -5.04, z0: z, z1: z + 3, y: -0.147, color: paint, mat: M.wall); z += 6 }   // centre dashes
        b.floor(x0: -2.25, x1: -2.15, z0: z0, z1: z1, y: -0.147, color: paint * 0.9, mat: M.wall)                          // edge lines
        b.floor(x0: -7.95, x1: -7.85, z0: z0, z1: z1, y: -0.147, color: paint * 0.9, mat: M.wall)
        // lamp posts every 12 m, staggered: near side at x 2.25 (arm toward the road), far side at x -8.6
        let pole = simd_float3(0.2, 0.21, 0.23)
        for i in 0..<3 {
            for (px, arm, zOff) in [(Float(2.25), Float(-1.1), Float(-3)), (Float(-8.6), Float(1.1), Float(-9))] {
                let pz = zOff - Float(i) * 12
                b.box(simd_float3(px - 0.07, 0, pz - 0.07), simd_float3(px + 0.07, 5.2, pz + 0.07), color: pole, mat: M.wall, faces: ["+x", "-x", "+z"])
                let ax0 = min(px, px + arm), ax1 = max(px, px + arm)
                b.box(simd_float3(ax0, 5.1, pz - 0.05), simd_float3(ax1, 5.2, pz + 0.05), color: pole, mat: M.wall, faces: ["+z", "+y"])
                let hx = px + arm
                b.box(simd_float3(hx - 0.3, 4.98, pz - 0.14), simd_float3(hx + 0.3, 5.1, pz + 0.14), color: simd_float3(1, 1, 1), mat: M.lamp, faces: ["+x", "-x", "+z", "-z"])
                b.quad(simd_float3(hx - 0.3, 4.98, pz - 0.14), simd_float3(hx + 0.3, 4.98, pz - 0.14), simd_float3(hx + 0.3, 4.98, pz + 0.14), simd_float3(hx - 0.3, 4.98, pz + 0.14), color: simd_float3(1, 1, 1), mat: M.lamp)   // glowing underside
            }
        }
        // buildings: far row facade at x -10 (faces +X), near row facade at x 2.6 (faces -X); widths 5-9 m, heights 6-24 m
        let palette: [simd_float3] = [simd_float3(0.55, 0.42, 0.36), simd_float3(0.62, 0.58, 0.5), simd_float3(0.42, 0.44, 0.48),
                                      simd_float3(0.68, 0.52, 0.4), simd_float3(0.36, 0.38, 0.44), simd_float3(0.58, 0.48, 0.44)]
        for side in [Float(-1), Float(1)] {
            let facade: Float = side < 0 ? -10 : 2.6, depth: Float = 7
            var zb = z0
            while zb < z1 - 2 {
                let w = min(r.range(5, 9), z1 - zb), h = r.range(6, 24)
                let col = palette[Int(r.next() * Float(palette.count)) % palette.count]
                let lo = simd_float3(side < 0 ? facade - depth : facade, 0, zb), hi = simd_float3(side < 0 ? facade : facade + depth, h, zb + w)
                b.box(lo, hi, color: col, mat: M.wall, faces: [side < 0 ? "+x" : "-x", "+z"])
                // windows: floors every 3.2 m from 3.6 m up, columns every 1.8 m; offset 3 cm off the facade
                let fx = facade + (side < 0 ? 0.03 : -0.03)
                let cols = max(1, Int((w - 0.8) / 1.8)), margin = (w - Float(cols) * 1.8) / 2 + 0.4
                var fy: Float = 3.6
                while fy + 1.4 < h - 0.6 {
                    for ci in 0..<cols {
                        let wz0 = zb + margin + Float(ci) * 1.8, wz1 = wz0 + 1.0
                        let mat = r.next() < 0.5 ? M.lit : M.dark
                        if side < 0 { b.quad(simd_float3(fx, fy, wz1), simd_float3(fx, fy, wz0), simd_float3(fx, fy + 1.4, wz0), simd_float3(fx, fy + 1.4, wz1), color: simd_float3(1, 1, 1), mat: mat) }
                        else { b.quad(simd_float3(fx, fy, wz0), simd_float3(fx, fy, wz1), simd_float3(fx, fy + 1.4, wz1), simd_float3(fx, fy + 1.4, wz0), color: simd_float3(1, 1, 1), mat: mat) }
                    }
                    fy += 3.2
                }
                // ground floor: a shop window band (glows at night)
                let s0 = zb + 0.6, s1 = zb + w - 0.6
                if s1 - s0 > 1.5 {
                    if side < 0 { b.quad(simd_float3(fx, 0.5, s1), simd_float3(fx, 0.5, s0), simd_float3(fx, 2.7, s0), simd_float3(fx, 2.7, s1), color: simd_float3(1, 1, 1), mat: M.shop) }
                    else { b.quad(simd_float3(fx, 0.5, s0), simd_float3(fx, 0.5, s1), simd_float3(fx, 2.7, s1), simd_float3(fx, 2.7, s0), color: simd_float3(1, 1, 1), mat: M.shop) }
                }
                zb += w + r.range(0, 1.6)
            }
        }
        return (b.geometry(materials: materials), b.triangles)
    }

    private static func makeCar(seed: UInt64) -> Car {
        let c = Car()
        c.body.lightingModel = .blinn; c.body.diffuse.contents = UIColor.red; c.body.specular.contents = UIColor(white: 0.5, alpha: 1)
        let glass = SCNMaterial(); glass.lightingModel = .constant; glass.diffuse.contents = UIColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1)
        let body = SCNNode(geometry: SCNBox(width: 1.8, height: 0.62, length: 4.2, chamferRadius: 0.12)); body.geometry?.materials = [c.body]; body.position = SCNVector3(0, 0.62, 0)
        let cabin = SCNNode(geometry: SCNBox(width: 1.55, height: 0.5, length: 2.1, chamferRadius: 0.14)); cabin.geometry?.materials = [glass]; cabin.position = SCNVector3(0, 1.17, -0.25)
        c.node.addChildNode(body); c.node.addChildNode(cabin)
        // two glowing discs per end: white headlights at the front (+Z), red tail lights at the back
        for (zEnd, color) in [(Float(2.11), UIColor(red: 1, green: 0.97, blue: 0.85, alpha: 1)), (Float(-2.11), UIColor(red: 1, green: 0.1, blue: 0.08, alpha: 1))] {
            for x in [Float(-0.62), Float(0.62)] {
                let disc = SCNCylinder(radius: 0.13, height: 0.03); disc.radialSegmentCount = 12
                let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = color; disc.materials = [m]
                let d = SCNNode(geometry: disc); d.name = "lamp"; d.eulerAngles = SCNVector3(Float.pi / 2, 0, 0); d.position = SCNVector3(x, 0.66, zEnd)
                c.node.addChildNode(d)
            }
        }
        return c
    }
}

/// Vertical colour bands (the sky): each band is one quad whose bottom/top vertices carry their row's colour.
struct MeshBuilderBands {
    private var positions: [SCNVector3] = []
    private var colors: [SIMD4<Float>] = []
    private var indices: [UInt32] = []
    mutating func band(x0: Float, x1: Float, z: Float, y0: Float, y1: Float, c0: simd_float3, c1: simd_float3) {
        let base = UInt32(positions.count)
        positions += [SCNVector3(x0, y0, z), SCNVector3(x1, y0, z), SCNVector3(x1, y1, z), SCNVector3(x0, y1, z)]
        colors += [SIMD4<Float>(c0, 1), SIMD4<Float>(c0, 1), SIMD4<Float>(c1, 1), SIMD4<Float>(c1, 1)]
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }
    func geometry(material: SCNMaterial) -> SCNGeometry {
        let v = SCNGeometrySource(vertices: positions)
        let data = colors.withUnsafeBufferPointer { Data(buffer: $0) }
        let c = SCNGeometrySource(data: data, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                  componentsPerVector: 4, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                  dataStride: MemoryLayout<SIMD4<Float>>.stride)
        let g = SCNGeometry(sources: [v, c], elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }
}
