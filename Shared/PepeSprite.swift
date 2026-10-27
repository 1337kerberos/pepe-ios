// 2D Pepe for the Live Activity: the embedded sprite for the state, or an SF Symbol when that sprite is not embedded.
import SwiftUI
import UIKit

struct SpriteView: View {
    let state: String
    let size: CGFloat
    var body: some View {
        if let ui = SpriteView.scaled(state, size) {
            Image(uiImage: ui).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: PepeStateStyle.symbol(state)).resizable().scaledToFit()
                .frame(width: size * 0.8, height: size * 0.8).padding(size * 0.1).foregroundStyle(.green)
        }
    }
}

extension SpriteView {
    /// 0.15: the Live Activity draws a grey placeholder for an image larger than its slot (seen in the simulator's
    /// Dynamic Island with the 256 px sprite in a 20 pt slot), so hand it a bitmap of the slot's pixel size (3x).
    static func scaled(_ state: String, _ size: CGFloat) -> UIImage? {
        guard let src = EmbeddedSprites.image(state) else { return nil }
        let px = max(1, (size * 3).rounded())
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: px, height: px), format: fmt).image { _ in
            src.draw(in: CGRect(x: 0, y: 0, width: px, height: px))
        }
    }
}

/// One dot per co-worker: green working, yellow waiting, grey otherwise.
struct AgentDots: View {
    let states: [String]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(states.prefix(6).enumerated()), id: \.offset) { _, s in
                Circle().fill(s == "working" || s == "thinking" ? Color.green : s == "waiting" ? Color.yellow : Color.gray.opacity(0.6)).frame(width: 7, height: 7)
            }
        }
    }
}
