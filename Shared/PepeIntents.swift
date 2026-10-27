// Buttons on the Lock Screen / Dynamic Island. A LiveActivityIntent runs in the APP's process (the system launches the app
// in the background if needed), so `perform()` hands the action to whatever the app registered in PepeIntentBridge; in the
// widget target the bridge is empty and the struct only exists so the button can be declared.
import AppIntents
import Foundation

enum PepeIntentBridge {
    /// set by the app at launch: ("summary" | "where") -> Void, async so it can wait for the brain connection
    static var handler: ((String) async -> Void)?
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
