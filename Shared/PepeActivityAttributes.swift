// Shared between the app and the widget extension (compiled into both targets).
import Foundation
#if canImport(ActivityKit)
import ActivityKit

struct PepeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var state: String   // idle | thinking | working | talking | done | error
        var line: String
        var emoji: String {
            switch state {
            case "thinking": return "🤔"
            case "working": return "⌨️"
            case "talking": return "💬"
            case "done": return "🎉"
            case "error": return "🤦"
            default: return "🐸"
            }
        }
    }
    var name: String
}
#endif
