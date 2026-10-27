// Live Activity views: Lock Screen banner + Dynamic Island (compact/minimal/expanded). 2D only: an emoji per state
// and the last status line (Live Activities cannot run frame animation; transitions are capped at 2 s).
import ActivityKit
import WidgetKit
import SwiftUI

struct PepeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PepeActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Text(context.state.emoji).font(.system(size: 40))
                VStack(alignment: .leading) {
                    Text("Pepe: \(context.state.state)").font(.headline)
                    Text(context.state.line).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.09, green: 0.11, blue: 0.16))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(context.state.emoji).font(.largeTitle) }
                DynamicIslandExpandedRegion(.center) { Text(context.state.state).font(.headline) }
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.line).font(.caption).lineLimit(2) }
            } compactLeading: {
                Text(context.state.emoji)
            } compactTrailing: {
                Text(context.state.state).font(.caption2).lineLimit(1)
            } minimal: {
                Text(context.state.emoji)
            }
        }
    }
}
