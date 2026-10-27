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
        /// 0.16: the question waiting for the user's OK (Allow / Deny buttons on the Lock Screen and in the Island)
        var ask: PepeAsk? = nil
        var asksWaiting: Int = 0

        /// everything but the timestamp: used to skip no-op updates
        var signature: String { "\(state)|\(line)|\(tool)|\(agentsWorking)|\(agentsTotal)|\(agentStates.joined(separator: ","))|\(ok.map { $0 ? "ok" : "err" } ?? "-")|\(ask?.id ?? "-")|\(ask?.sent ?? "")|\(asksWaiting)" }
    }
    var name: String
}

/// 0.16: a pending brain `ask` ({"type":"ask","id","text","kind","options","ttl_s","expires","origin","tool","cwd"}).
/// `expires` is on the PHONE's clock (the brain's expires minus the clock offset). `sent` = the answer this phone already
/// sent and is waiting to see resolved ("" = none).
struct PepeAsk: Codable, Hashable, Identifiable {
    var id: String
    var text: String
    var kind: String          // tool | action | question
    var origin: String        // brain (Pepe's own session) | claude-code (the PreToolUse gate)
    var tool: String
    var cwd: String
    var expires: Date
    var sent: String = ""

    /// the question without the "<cwd> wants to " lead-in when the source line already names the cwd:
    /// "Run: git push origin main (changes git history or the remote)"
    var shortText: String {
        let lead = "\(cwd) wants to "
        guard origin != "brain", !cwd.isEmpty, text.hasPrefix(lead) else { return text }
        let rest = String(text.dropFirst(lead.count))
        return rest.prefix(1).uppercased() + rest.dropFirst()
    }

    /// one short line naming who asks: "solana-microstructure · Bash" or "Pepe"
    var source: String {
        if origin == "brain" { return kind == "tool" && !tool.isEmpty ? "Pepe · \(tool)" : "Pepe" }
        return [cwd.isEmpty ? "Claude Code" : cwd, tool].filter { !$0.isEmpty }.joined(separator: " · ")
    }
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
