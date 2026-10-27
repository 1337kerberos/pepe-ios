// Live Activity views: Lock Screen banner + Dynamic Island (compact / minimal / expanded). 2D only: the state sprite
// (EmbeddedSprites, SF Symbol fallback), the state label, the last line, co-worker dots and two intent buttons.
import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

struct PepeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PepeActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.09, green: 0.11, blue: 0.16))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SpriteView(state: context.state.state, size: 44).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Pepe: \(PepeStateStyle.label(context.state.state))").font(.headline)
                            if let ok = context.state.ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red).font(.caption) }
                        }
                        Text(context.state.line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 3) {
                        if context.state.agentsTotal > 0 { Text("\(context.state.agentsWorking)/\(context.state.agentsTotal)").font(.caption2.monospacedDigit()) }
                        AgentDots(states: context.state.agentStates)
                    }.padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) { ButtonsRow().padding(.top, 2) }
            } compactLeading: {
                SpriteView(state: context.state.state, size: 20)
            } compactTrailing: {
                Image(systemName: PepeStateStyle.symbol(context.state.state)).foregroundStyle(.green)
            } minimal: {
                SpriteView(state: context.state.state, size: 18)
            }
        }
    }
}

struct LockScreenView: View {
    let state: PepeActivityAttributes.ContentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                SpriteView(state: state.state, size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Pepe: \(PepeStateStyle.label(state.state))").font(.headline).foregroundStyle(.white)
                        if let ok = state.ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red).font(.caption) }
                        Spacer()
                        Text(state.updatedAt, style: .time).font(.caption2).foregroundStyle(.white.opacity(0.5))
                    }
                    Text(state.line).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    if !state.tool.isEmpty { Text(state.tool).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                    if state.agentsTotal > 0 {
                        HStack(spacing: 6) {
                            AgentDots(states: state.agentStates)
                            Text("\(state.agentsWorking) of \(state.agentsTotal) agents working").font(.caption2).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
            ButtonsRow()
        }
        .padding(14)
    }
}

struct ButtonsRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: PepeSummaryIntent()) { Label("Summary", systemImage: "text.bubble") }
            Button(intent: PepeWhereIntent()) { Label("Where", systemImage: "location") }
        }
        .buttonStyle(.bordered).tint(.green).font(.caption.bold())
    }
}
