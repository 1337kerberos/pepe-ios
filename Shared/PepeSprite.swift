// 2D Pepe for the Live Activity: the embedded sprite for the state, or an SF Symbol when that sprite is not embedded.
import SwiftUI

struct SpriteView: View {
    let state: String
    let size: CGFloat
    var body: some View {
        if let ui = EmbeddedSprites.image(state) {
            Image(uiImage: ui).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: PepeStateStyle.symbol(state)).resizable().scaledToFit()
                .frame(width: size * 0.8, height: size * 0.8).padding(size * 0.1).foregroundStyle(.green)
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
