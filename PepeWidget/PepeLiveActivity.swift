// Live Activity views: Lock Screen banner + Dynamic Island (compact / minimal / expanded). 2D only: the state sprite
// (EmbeddedSprites, SF Symbol fallback), the state label, the last line, co-worker dots and two intent buttons.
// 0.16: while a question waits (state.ask) the Lock Screen and the expanded Island show it with Allow / Deny, the
// compact Island shows a ticking countdown, the keyline turns orange and the "?" pulses; the app sends the update with
// an AlertConfiguration, which lights the Lock Screen and expands the Island on the device.
// LockScreenView / ButtonsRow / the ask views live in Shared/PepeActivityViews.swift (the app renders them too).
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
            let ask = context.state.ask
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { SpriteView(state: ask != nil ? "waiting" : context.state.state, size: 44).padding(.leading, 4) }
                DynamicIslandExpandedRegion(.center) {
                    if let ask {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).symbolEffect(.pulse, options: .repeating)
                                Text("Needs your OK").font(.headline).lineLimit(1)
                            }
                            Text(ask.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Pepe: \(PepeStateStyle.label(context.state.state))").font(.headline)
                                if let ok = context.state.ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red).font(.caption) }
                            }
                            Text(context.state.line).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let ask {
                        AskCountdown(expires: ask.expires).font(.caption.bold()).foregroundStyle(.orange).frame(width: 44, alignment: .trailing).padding(.trailing, 4)
                    } else {
                        VStack(alignment: .trailing, spacing: 3) {
                            if context.state.agentsTotal > 0 { Text("\(context.state.agentsWorking)/\(context.state.agentsTotal)").font(.caption2.monospacedDigit()) }
                            AgentDots(states: context.state.agentStates)
                        }.padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let ask { AskButtons(ask: ask, height: 36).padding(.top, 2) } else { ButtonsRow().padding(.top, 2) }
                }
            } compactLeading: {
                SpriteView(state: ask != nil ? "waiting" : context.state.state, size: 20)
            } compactTrailing: {
                if let ask {
                    AskCountdown(expires: ask.expires).font(.caption2.bold()).foregroundStyle(.orange).frame(maxWidth: 38)
                } else {
                    Image(systemName: PepeStateStyle.symbol(context.state.state)).foregroundStyle(.green)
                }
            } minimal: {
                if ask != nil {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).symbolEffect(.pulse, options: .repeating)
                } else {
                    SpriteView(state: context.state.state, size: 18)
                }
            }
            .keylineTint(ask != nil ? .orange : .green)
        }
    }
}
