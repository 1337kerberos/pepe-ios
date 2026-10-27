// Buttons on the Lock Screen / Dynamic Island. A LiveActivityIntent runs in the APP's process (the system launches the app
// in the background if needed), so `perform()` hands the action to whatever the app registered in PepeIntentBridge; in the
// widget target the bridge is empty and the struct only exists so the button can be declared.
import AppIntents
import Foundation

enum PepeIntentBridge {
    /// set by the app at launch: ("summary" | "where") -> Void, async so it can wait for the brain connection
    static var handler: ((String) async -> Void)?
    /// 0.16: (ask id, "allow" | "deny") -> sends {"type":"ask_answer"} through the app's socket (waits up to 6 s for it)
    static var answer: ((String, String) async -> Void)?
}

/// 0.16: Allow / Deny on a pending ask (Lock Screen, Dynamic Island, the in-app Lock Screen preview).
struct PepeAskAnswerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Answer Pepe"
    static var description = IntentDescription("Allow or deny what Pepe (or a Claude Code session) is asking.")
    static var openAppWhenRun = false
    static var isDiscoverable = false
    @Parameter(title: "Ask id") var askId: String
    @Parameter(title: "Answer") var answer: String
    init() {}
    init(askId: String, answer: String) { self.askId = askId; self.answer = answer }
    func perform() async throws -> some IntentResult {
        await PepeIntentBridge.answer?(askId, answer)
        return .result()
    }
}

struct PepeSummaryIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pepe summary"
    static var description = IntentDescription("Ask Pepe for a one-line status.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await PepeIntentBridge.handler?("summary")
        return .result()
    }
}

struct PepeWhereIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Where is Pepe"
    static var description = IntentDescription("Ask Pepe where he is: which directory and which step.")
    static var openAppWhenRun = false
    func perform() async throws -> some IntentResult {
        await PepeIntentBridge.handler?("where")
        return .result()
    }
}
