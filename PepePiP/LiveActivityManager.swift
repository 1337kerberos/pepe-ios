// Live Activity mirror (Dynamic Island / Lock Screen): same state as a 2D emoji + the last status line.
// Scaffolded: needs the PepeWidget extension target (project-widget.yml) to actually show anything.
import Foundation
import ActivityKit

final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var lastUpdate: TimeInterval = 0
    private var lastState = ""
    private var activity: Activity<PepeActivityAttributes>?

    func update(state: String, line: String, enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { end(); return }
        let now = Date().timeIntervalSince1970
        // Apple throttles updates; ~one per 5 s is plenty for a status line (state changes go through at once).
        guard state != lastState || now - lastUpdate > 5 else { return }
        lastState = state; lastUpdate = now
        let content = ActivityContent(state: PepeActivityAttributes.ContentState(state: state, line: String(line.prefix(60))), staleDate: nil)
        Task {
            if let a = activity { await a.update(content) }
            else {
                do { activity = try Activity.request(attributes: PepeActivityAttributes(name: "Pepe"), content: content, pushType: nil) }
                catch { Log.add("live activity: \(error)") }
            }
        }
    }

    func end() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
