// Live Activity mirror (Dynamic Island / Lock Screen): the same state as a 2D sprite + the last line + co-worker dots.
// Needs the PepeWidget extension (project-widget.yml) INSIDE the installed app to show anything: iLoader / Sideloader
// installs have it, LiveContainer cannot run extensions at all. This side only starts/updates/ends.
//
// 0.15 (first device test: "nothing on the Lock Screen"): every step is visible in Settings > Live Activity:
//  - phase: not started / requested / active <id> / ended (why) / denied (error) / disabled; the last error text;
//    ActivityAuthorizationInfo().areActivitiesEnabled and frequentPushesEnabled; widget appex present/missing.
//  - Start / End buttons (Start bypasses the throttle and the "user ended it" latch).
//  - Activity.request(attributes:content:pushType: nil) carries the first ContentState (iOS draws nothing without one);
//    an explicit update with the same state follows right away. No push token is requested (pushType nil), so no
//    push-to-start / APNs path exists that could throw on iOS 26 (the request call itself is unchanged since 16.2).
//  - Started at launch once the scene is up (brain or not) and on brain connect; kept alive while the brain is offline
//    (state "offline" + the local status line) instead of ending after 30 min. Re-requested on foreground if iOS
//    ended it, unless the user tapped End.
import Foundation
import ActivityKit
import UIKit

final class LiveActivityManager: ObservableObject {
    static let shared = LiveActivityManager()
    private var activity: Activity<PepeActivityAttributes>?
    private var lastSignature = ""
    private var lastUpdate: TimeInterval = 0
    private var pending: PepeActivityAttributes.ContentState?
    private var trailing: DispatchWorkItem?
    private var lastContent: PepeActivityAttributes.ContentState?
    private var userEnded = false
    private var lastRequestAt: TimeInterval = 0
    private var observer: Task<Void, Never>?
    static let minInterval: TimeInterval = 3

    @Published private(set) var phase = "not started"
    @Published private(set) var lastError = ""
    @Published private(set) var updatesSent = 0
    @Published private(set) var lastSentLine = ""

    private init() {
        // re-adopt an activity that survived a relaunch; end extra ones
        let all = Activity<PepeActivityAttributes>.activities
        if let a = all.first {
            adopt(a); phase = "active \(a.id.prefix(8)) (re-adopted, \(a.activityState))"
            Log.add("live activity: re-adopted \(a.id) state \(a.activityState)")
        }
        for extra in all.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.end(reason: "app quit") }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.foreground() }
    }

    var isRunning: Bool { activity != nil }
    var activityId: String { activity?.id ?? "" }
    static var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    static var frequentUpdates: Bool { ActivityAuthorizationInfo().frequentPushesEnabled }

    /// The widget extension the system needs to draw the activity, looked up in OUR bundle (Bundle.main is the host's
    /// inside LiveContainer).
    static var widgetURL: URL? { AppResources.ownBundle.builtInPlugInsURL?.appendingPathComponent("PepeWidget.appex") }
    static var widgetPresent: Bool { widgetURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Throttled to one update per 3 s and only when the content (minus the timestamp) changed; a change that arrives
    /// inside the window is delivered when the window closes, so the latest state always lands.
    func update(_ s: PepeActivityAttributes.ContentState, enabled: Bool) {
        lastContent = s
        guard enabled else { if activity != nil { end(reason: "toggle off") }; return }
        guard LiveActivityManager.enabled else {
            if phase != "disabled" { phase = "disabled"; lastError = "areActivitiesEnabled = false (iOS Settings > Pepe > Live Activities, or no widget/host support)"; Log.add("live activity: \(lastError)") }
            if activity != nil { end(reason: "activities disabled") }
            return
        }
        if activity == nil && userEnded { return }
        if activity == nil, Date().timeIntervalSince1970 - lastRequestAt < 30 { return }   // a failed request is retried at most every 30 s
        guard s.signature != lastSignature || activity == nil else { return }
        let now = Date().timeIntervalSince1970
        if activity != nil, now - lastUpdate < LiveActivityManager.minInterval {
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
        send(s)
    }

    /// Settings > Live Activity > Start: request now (or push the current state into the running one)
    func start(_ s: PepeActivityAttributes.ContentState, reason: String) {
        userEnded = false
        lastContent = s
        Log.add("live activity: start (\(reason)); enabled \(LiveActivityManager.enabled), widget \(LiveActivityManager.widgetPresent ? "present" : "MISSING")")
        if let a = activity, a.activityState == .active { lastSignature = ""; send(s); return }
        activity = nil
        send(s)
    }

    private func content(_ s: PepeActivityAttributes.ContentState) -> ActivityContent<PepeActivityAttributes.ContentState> {
        ActivityContent(state: s, staleDate: Date().addingTimeInterval(60 * 60))
    }

    /// request (synchronous, on the main thread: Activity.request must be called while the app is in the foreground)
    /// or update the running activity
    private func send(_ s: PepeActivityAttributes.ContentState) {
        lastSignature = s.signature; lastUpdate = Date().timeIntervalSince1970
        let c = content(s)
        if let a = activity, a.activityState == .active || a.activityState == .stale {
            Task { await a.update(c) }
            updatesSent += 1; lastSentLine = "\(s.state): \(s.line)"
            return
        }
        activity = nil
        phase = "requested"
        lastRequestAt = Date().timeIntervalSince1970
        do {
            let a = try Activity.request(attributes: PepeActivityAttributes(name: "Pepe"), content: c, pushType: nil)
            adopt(a)
            phase = "active \(a.id.prefix(8)) (\(a.activityState))"
            lastError = ""
            Log.add("live activity: started \(a.id) state \(a.activityState) (widget \(LiveActivityManager.widgetPresent ? "present" : "MISSING"))")
            Task { await a.update(c) }            // belt and braces: the first state is in the request already
            updatesSent += 1; lastSentLine = "\(s.state): \(s.line)"
        } catch {
            let ns = error as NSError
            phase = "denied"
            lastError = "\(error) [\(ns.domain) \(ns.code)] \(ns.localizedDescription)"
            Log.add("live activity: request failed \(lastError)")
        }
    }

    private func adopt(_ a: Activity<PepeActivityAttributes>) {
        activity = a
        observer?.cancel()
        let id = a.id
        observer = Task {
            for await st in a.activityStateUpdates {
                DispatchQueue.main.async { LiveActivityManager.shared.stateChanged(id: id, st) }
            }
        }
    }

    private func stateChanged(id: String, _ st: ActivityState) {
        guard activity?.id == id else { return }
        Log.add("live activity: \(id.prefix(8)) -> \(st)")
        if st == .active || st == .stale { phase = "active \(id.prefix(8)) (\(st))" }
        else { phase = "ended (\(st))"; activity = nil; lastSignature = "" }
    }

    /// Brain connectivity: nothing ends any more; the content says offline (PepeModel.refreshLiveActivity).
    func brainConnected(_ up: Bool) {
        Log.add("live activity: brain \(up ? "up" : "down"), activity \(activity == nil ? "none" : "running")")
    }

    /// iOS may end an activity (8 h limit, the user swiped it away): bring it back when the app comes forward
    private func foreground() {
        guard activity == nil, !userEnded, let s = lastContent, PepeModel.shared.liveActivity, LiveActivityManager.enabled else { return }
        Log.add("live activity: foreground, none running -> request")
        lastSignature = ""; send(s)
    }

    /// Settings > Live Activity > End
    func userEnd() { userEnded = true; end(reason: "End tapped") }

    func end(reason: String) {
        trailing?.cancel(); trailing = nil; pending = nil
        guard let a = activity else { phase = "ended (\(reason))"; return }
        activity = nil; lastSignature = ""
        phase = "ended (\(reason))"
        Log.add("live activity: end (\(reason))")
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
