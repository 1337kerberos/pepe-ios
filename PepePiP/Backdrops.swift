// Procedural textures drawn with Core Graphics at runtime: no loose PNGs, so the backdrop can never be missing
// (LiveContainer broke Bundle.main lookups). Same looks as the former tools/make_backgrounds.py / make_puff.py output.
import UIKit

enum Backdrops {
    static let lounge: UIImage = draw(1024) { ctx, s in
        linear(ctx, s, top: rgb(0.20, 0.12, 0.09), bottom: rgb(0.07, 0.045, 0.04))
        radial(ctx, s, center: CGPoint(x: 0.22, y: 0.12), radius: 0.55, color: rgb(0.55, 0.36, 0.18), alpha: 0.9)     // warm spot upper-left
        radial(ctx, s, center: CGPoint(x: 0.88, y: 0.25), radius: 0.38, color: rgb(0.10, 0.16, 0.26), alpha: 0.9)     // cool rim glow upper-right
        linear(ctx, s, top: UIColor(white: 0, alpha: 0), bottom: rgb(0.06, 0.035, 0.025, 0.9), from: 0.72)            // lighter floor band
        vignette(ctx, s, strength: 0.55)
    }

    static let office: UIImage = draw(1024) { ctx, s in
        linear(ctx, s, top: rgb(0.40, 0.46, 0.55), bottom: rgb(0.18, 0.21, 0.27))
        // blurred desk silhouette: dark shapes with a wide shadow for the blur
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0.012 * s, color: UIColor(white: 0, alpha: 0.9).cgColor)
        ctx.setFillColor(rgb(0.10, 0.12, 0.16, 0.7).cgColor)
        ctx.fill(CGRect(x: 0, y: 0.80 * s, width: s, height: 0.06 * s))                                 // desk top
        ctx.fill(CGRect(x: 0.06 * s, y: 0.86 * s, width: 0.04 * s, height: 0.14 * s))                   // legs
        ctx.fill(CGRect(x: 0.90 * s, y: 0.86 * s, width: 0.04 * s, height: 0.14 * s))
        ctx.fill(CGRect(x: 0.12 * s, y: 0.64 * s, width: 0.22 * s, height: 0.16 * s))                   // monitor
        ctx.fill(CGRect(x: 0.40 * s, y: 0.70 * s, width: 0.12 * s, height: 0.10 * s))                   // mug / stack
        ctx.restoreGState()
        // window light: four soft panes
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0.02 * s, color: rgb(0.75, 0.82, 0.92, 0.9).cgColor)
        ctx.setFillColor(rgb(0.72, 0.78, 0.86, 0.85).cgColor)
        let w = CGRect(x: 0.58 * s, y: 0.14 * s, width: 0.32 * s, height: 0.38 * s)
        let gap = 0.012 * s
        for i in 0..<2 { for j in 0..<2 {
            ctx.fill(CGRect(x: w.minX + CGFloat(i) * (w.width / 2 + gap / 2), y: w.minY + CGFloat(j) * (w.height / 2 + gap / 2), width: w.width / 2 - gap / 2, height: w.height / 2 - gap / 2))
        } }
        ctx.restoreGState()
        vignette(ctx, s, strength: 0.4)
    }

    static let neon: UIImage = draw(1024) { ctx, s in
        ctx.setFillColor(rgb(0.03, 0.02, 0.05).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
        linear(ctx, s, top: UIColor(white: 0, alpha: 0), bottom: rgb(0.13, 0.06, 0.21, 1), from: 0.6)   // violet floor haze
    }

    /// RGBA: a soft dark ellipse (contact shadow), transparent elsewhere.
    static let floorShadow: UIImage = draw(512, opaque: false) { ctx, s in
        ctx.saveGState(); ctx.translateBy(x: s / 2, y: s / 2); ctx.scaleBy(x: 1, y: 0.72)
        radialGradient(ctx, radius: 0.28 * s, stops: [(0, 0.75), (0.3, 0.6), (0.6, 0.28), (0.85, 0.06), (1, 0)], color: .black)
        ctx.restoreGState()
    }

    /// RGBA white radial glow (neon blobs, tinted by the material).
    static let glow: UIImage = draw(256, opaque: false) { ctx, s in
        ctx.saveGState(); ctx.translateBy(x: s / 2, y: s / 2)
        radialGradient(ctx, radius: s / 2, stops: [(0, 1), (0.25, 0.5), (0.5, 0.18), (0.75, 0.04), (1, 0)], color: .white)
        ctx.restoreGState()
    }

    /// RGBA smoke sprite: white, alpha (1-r)^2.2.
    static let puff: UIImage = draw(64, opaque: false) { ctx, s in
        ctx.saveGState(); ctx.translateBy(x: s / 2, y: s / 2)
        radialGradient(ctx, radius: s / 2, stops: [(0, 1), (0.25, 0.53), (0.5, 0.22), (0.75, 0.047), (1, 0)], color: .white)
        ctx.restoreGState()
    }

    // MARK: helpers
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    private static func draw(_ size: CGFloat, opaque: Bool = true, _ body: (CGContext, CGFloat) -> Void) -> UIImage {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = opaque
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: f).image { r in body(r.cgContext, size) }
    }

    private static func linear(_ ctx: CGContext, _ s: CGFloat, top: UIColor, bottom: UIColor, from: CGFloat = 0) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: from * s), end: CGPoint(x: 0, y: s), options: [.drawsAfterEndLocation])
    }

    /// additive-looking soft glow: colour fades to clear with a smooth falloff
    private static func radial(_ ctx: CGContext, _ s: CGFloat, center: CGPoint, radius: CGFloat, color: UIColor, alpha: CGFloat) {
        ctx.saveGState(); ctx.translateBy(x: center.x * s, y: center.y * s); ctx.setBlendMode(.plusLighter)
        radialGradient(ctx, radius: radius * s, stops: [(0, alpha), (0.3, alpha * 0.55), (0.6, alpha * 0.2), (0.85, alpha * 0.04), (1, 0)], color: color)
        ctx.restoreGState()
    }

    private static func radialGradient(_ ctx: CGContext, radius: CGFloat, stops: [(CGFloat, CGFloat)], color: UIColor) {
        let colors = stops.map { color.withAlphaComponent($0.1).cgColor } as CFArray
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: stops.map { $0.0 })!
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    }

    private static func vignette(_ ctx: CGContext, _ s: CGFloat, strength: CGFloat) {
        ctx.saveGState(); ctx.translateBy(x: s / 2, y: s / 2); ctx.scaleBy(x: 1, y: 0.92)
        radialGradient(ctx, radius: 0.72 * s, stops: [(0, 0), (0.45, strength * 0.1), (0.75, strength * 0.45), (1, strength)], color: .black)
        ctx.restoreGState()
    }
}
