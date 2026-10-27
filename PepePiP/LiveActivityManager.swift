// Live Activity mirror (Dynamic Island / Lock Screen): the same state as a 2D sprite + the last line + co-worker dots.
// Needs the PepeWidget extension target (project-widget.yml) to show anything; this side only starts/updates/ends.
import Foundation
import ActivityKit
import UIKit

final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<PepeActivityAttributes>?
    private var lastSignature = ""
    private var lastUpdate: TimeInterval = 0
    private var pending: PepeActivityAttributes.ContentState?
    private var trailing: DispatchWorkItem?
    private var offlineTimer: Timer?
    static let minInterval: TimeInterval = 3
    static let offlineEndAfter: TimeInterval = 30 * 60

    private init() {
        // re-adopt an activity that survived a relaunch
        if let a = Activity<PepeActivityAttributes>.activities.first { activity = a; Log.add("live activity: re-adopted \(a.id)") }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.end(reason: "app quit") }
    }

    var isRunning: Bool { activity != nil }

    /// Throttled to one update per 3 s and only when the content (minus the timestamp) changed; a change that arrives
    /// inside the window is delivered when the window closes, so the latest state always lands.
    func update(_ s: PepeActivityAttributes.ContentState, enabled: Bool) {
        guard enabled, ActivityAuthorizationInfo().areActivitiesEnabled else { if activity != nil { end(reason: enabled ? "activities disabled" : "toggle off") }; return }
        guard s.signature != lastSignature else { return }
        let now = Date().timeIntervalSince1970
        if now - lastUpdate < LiveActivityManager.minInterval {
            pending = s
            if trailing == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.trailing = nil
                    if let p = self.pending { self.pending = nil; self.update(p, enabled: enabled) }
                }
                trailing = w
                DispatchQueue.main.asyncAfter(deadline: .now() + (LiveActivityManager.minInterval - (now - lastUpdate)) + 0.05, execute: w)
            }
            return
        }
        lastSignature = s.signature; lastUpdate = now
        let content = ActivityContent(state: s, staleDate: Date().addingTimeInterval(15 * 60))
        Task {
            if let a = activity, a.activityState == .active { await a.update(content) }
            else {
                do {
                    activity = try Activity.request(attributes: PepeActivityAttributes(name: "Pepe"), content: content, pushType: nil)
                    Log.add("live activity: started \(activity?.id ?? "?")")
                } catch { Log.add("live activity: request failed \(error)") }
            }
        }
    }

    /// Brain connectivity: online cancels the offline countdown; offline ends the activity after 30 min.
    func brainConnected(_ up: Bool) {
        offlineTimer?.invalidate(); offlineTimer = nil
        if !up, activity != nil {
            offlineTimer = Timer.scheduledTimer(withTimeInterval: LiveActivityManager.offlineEndAfter, repeats: false) { [weak self] _ in self?.end(reason: "30 min offline") }
        }
    }

    func end(reason: String) {
        trailing?.cancel(); trailing = nil; pending = nil
        guard let a = activity else { return }
        activity = nil; lastSignature = ""
        Log.add("live activity: end (\(reason))")
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
