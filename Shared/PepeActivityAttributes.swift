// Shared between the app and the widget extension (compiled into both targets).
import Foundation
import ActivityKit

struct PepeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var state: String          // idle | thinking | working | waiting | celebrating | failing | smoking | sleeping
        var line: String           // last text / status, <= 80 chars
        var tool: String           // last tool name ("" when none)
        var agentsWorking: Int     // co-workers currently working
        var agentsTotal: Int
        var agentStates: [String]  // per co-worker state for the dot row (cap 6)
        var ok: Bool?              // last result: nil = none yet
        var updatedAt: Date

        /// everything but the timestamp: used to skip no-op updates
        var signature: String { "\(state)|\(line)|\(tool)|\(agentsWorking)|\(agentsTotal)|\(agentStates.joined(separator: ","))|\(ok.map { $0 ? "ok" : "err" } ?? "-")" }
    }
    var name: String
}

/// Labels / glyphs per state (one place for the app, the Lock Screen and the Island).
enum PepeStateStyle {
    static func label(_ state: String) -> String {
        switch state {
        case "thinking": return "thinking"; case "working": return "working"; case "waiting": return "needs you"
        case "celebrating": return "done"; case "failing": return "went wrong"; case "smoking": return "smoke break"
        case "sleeping": return "offline"; default: return "idle"
        }
    }
    /// SF Symbol per state: the compact-trailing glyph and the fallback when a sprite is missing
    static func symbol(_ state: String) -> String {
        switch state {
        case "thinking": return "brain.head.profile"; case "working": return "keyboard"; case "waiting": return "questionmark.bubble"
        case "celebrating": return "party.popper"; case "failing": return "exclamationmark.triangle"; case "smoking": return "smoke"
        case "sleeping": return "zzz"; default: return "face.smiling"
        }
    }
}
