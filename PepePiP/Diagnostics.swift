// 0.15 diagnostics: Settings > Live Activity (start/end + every state the owner needs to see) and Settings > Debug (one
// screen to screenshot: permissions, recognizer, audio session, PiP, brain, Live Activity, build, install kind, the last
// 50 log lines; Copy / Share put the whole report on the clipboard / share sheet).
import SwiftUI
import UIKit
import AVFoundation
import AVKit
import Speech
import UserNotifications
import ActivityKit

enum InstallInfo {
    static var ownPath: String { AppResources.ownBundle.bundlePath }
    static var mainPath: String { Bundle.main.bundlePath }
    static var hasProfile: Bool { FileManager.default.fileExists(atPath: AppResources.ownBundle.bundleURL.appendingPathComponent("embedded.mobileprovision").path) }

    /// LiveContainer runs guest apps from its own Documents / app-group folder and (older versions) leaves Bundle.main
    /// pointing at the host; a real install lives under /var/containers/Bundle/Application/<uuid>/.
    static var kind: String {
        #if targetEnvironment(simulator)
        return "simulator"
        #else
        let own = ownPath, main = mainPath
        let ownId = AppResources.ownBundle.bundleIdentifier ?? "?", mainId = Bundle.main.bundleIdentifier ?? "?"
        if ownId != mainId || own != main { return "LiveContainer guest (host \(mainId))" }
        let env = ProcessInfo.processInfo.environment
        if own.localizedCaseInsensitiveContains("livecontainer") || env.keys.contains(where: { $0.hasPrefix("LC_") }) { return "LiveContainer guest" }
        if own.contains("/containers/Bundle/Application/") { return hasProfile ? "real install (sideloaded, profile embedded)" : "real install (no provisioning profile)" }
        return "unknown (bundle not under containers/Bundle/Application: likely LiveContainer)"
        #endif
    }
    static var isLiveContainer: Bool { kind.hasPrefix("LiveContainer") || kind.hasPrefix("unknown") }

    static func plistFlag(_ b: Bundle, _ key: String) -> String {
        guard let v = b.object(forInfoDictionaryKey: key) else { return "missing" }
        if let n = v as? Bool { return n ? "YES" : "NO" }
        return "set"
    }
}

/// The report, as rows: the Debug screen renders it and Copy / Share send the same text.
struct DiagRow: Identifiable { let id = UUID(); let key: String; let value: String; var bad = false }
struct DiagSection: Identifiable { let id = UUID(); let title: String; let rows: [DiagRow] }

enum Diagnostics {
    static func sections(model: PepeModel, notif: String) -> [DiagSection] {
        let la = LiveActivityManager.shared
        let s = AVAudioSession.sharedInstance()
        let u = Voice.usageStringsPresent
        let widget = LiveActivityManager.widgetPresent
        return [
            DiagSection(title: "Build / install", rows: [
                DiagRow(key: "version", value: PepeModel.versionLine),
                DiagRow(key: "install", value: InstallInfo.kind, bad: InstallInfo.isLiveContainer),
                DiagRow(key: "widget appex", value: widget ? "present (PlugIns/PepeWidget.appex)" : "MISSING (app-only IPA or LiveContainer: no Lock Screen / Island)", bad: !widget),
                DiagRow(key: "bundle", value: InstallInfo.ownPath),
                DiagRow(key: "Bundle.main", value: InstallInfo.mainPath == InstallInfo.ownPath ? "same" : InstallInfo.mainPath),
                DiagRow(key: "iOS", value: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion), \(UIDevice.current.model)"),
            ]),
            DiagSection(title: "Permissions", rows: [
                DiagRow(key: "microphone", value: Voice.micStatus, bad: Voice.micStatus != "granted"),
                DiagRow(key: "speech recognition", value: Voice.speechStatus, bad: Voice.speechStatus != "authorized"),
                DiagRow(key: "notifications", value: notif),
                DiagRow(key: "usage strings (running plist)", value: "mic \(u.mic ? "yes" : "NO"), speech \(u.speech ? "yes" : "NO")", bad: !(u.mic && u.speech)),
                DiagRow(key: "NSSupportsLiveActivities", value: "own \(InstallInfo.plistFlag(AppResources.ownBundle, "NSSupportsLiveActivities")), running \(InstallInfo.plistFlag(Bundle.main, "NSSupportsLiveActivities"))"),
            ]),
            DiagSection(title: "Voice", rows: [
                DiagRow(key: "talk mode", value: model.talkMode == "hold" ? "hold to talk" : "tap to talk"),
                DiagRow(key: "microphone setting", value: model.micOn ? "on" : "OFF", bad: !model.micOn),
                DiagRow(key: "language setting", value: model.speechLang + " (phone \(Locale.current.identifier))"),
                DiagRow(key: "recognizer", value: model.voice.recognizerSummary),
                DiagRow(key: "voice state", value: "\(model.voice.ui.label)\(model.voice.ui.line.isEmpty ? "" : ": \(model.voice.ui.line)")", bad: model.voice.ui.lineIsError),
            ]),
            DiagSection(title: "Audio session", rows: [
                DiagRow(key: "category / mode", value: AudioKeepAlive.categorySummary),
                DiagRow(key: "route", value: AudioKeepAlive.routeSummary),
                DiagRow(key: "input", value: AudioKeepAlive.inputSummary, bad: !s.isInputAvailable),
                DiagRow(key: "other audio playing", value: s.isOtherAudioPlaying ? "yes" : "no"),
                DiagRow(key: "keep-alive engine", value: AudioKeepAlive.shared.isRunning ? "running" : "stopped"),
            ]),
            DiagSection(title: "PiP / brain", rows: [
                DiagRow(key: "PiP supported", value: AVPictureInPictureController.isPictureInPictureSupported() ? "yes" : "NO"),
                DiagRow(key: "PiP active", value: model.pipActive ? "yes" : "no"),
                DiagRow(key: "PiP path", value: model.pipMode.label),
                DiagRow(key: "brain", value: model.connected ? "connected" : "OFFLINE", bad: !model.connected),
                DiagRow(key: "dialing", value: "\(model.effectiveHost.host):\(model.effectiveHost.port) (\(model.effectiveHost.source))"),
                DiagRow(key: "status", value: model.status),
            ]),
            DiagSection(title: "Live Activity", rows: [
                DiagRow(key: "toggle", value: model.liveActivity ? "on" : "OFF"),
                DiagRow(key: "areActivitiesEnabled", value: LiveActivityManager.enabled ? "true" : "FALSE", bad: !LiveActivityManager.enabled),
                DiagRow(key: "frequent updates", value: LiveActivityManager.frequentUpdates ? "true" : "false"),
                DiagRow(key: "state", value: la.phase, bad: la.phase.hasPrefix("denied") || la.phase == "disabled"),
                DiagRow(key: "updates sent", value: "\(la.updatesSent)\(la.lastSentLine.isEmpty ? "" : ", last \(la.lastSentLine)")"),
                DiagRow(key: "last error", value: la.lastError.isEmpty ? "none" : la.lastError, bad: !la.lastError.isEmpty),
            ]),
        ]
    }

    static func notificationStatus(_ done: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let v: String
            switch st.authorizationStatus {
            case .authorized: v = "authorized"; case .denied: v = "denied"; case .notDetermined: v = "not asked"
            case .provisional: v = "provisional"; case .ephemeral: v = "ephemeral"; @unknown default: v = "unknown"
            }
            DispatchQueue.main.async { done(v) }
        }
    }

    static func report(model: PepeModel, notif: String) -> String {
        var out = ["Pepe diagnostics \(Date())"]
        for sec in sections(model: model, notif: notif) {
            out.append("== \(sec.title)")
            for r in sec.rows { out.append("\(r.bad ? "!" : " ") \(r.key): \(r.value)") }
        }
        out.append("== log (last 50)")
        out += Log.lines.suffix(50)
        return out.joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: PepeModel
    @ObservedObject var la = LiveActivityManager.shared
    @ObservedObject var voiceUI: VoiceUI
    @State var notif = "checking"
    @State var copied = false
    @State var refresh = 0

    var body: some View {
        let secs = Diagnostics.sections(model: model, notif: notif)
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack {
                        Button { UIPasteboard.general.string = Diagnostics.report(model: model, notif: notif); copied = true } label: { Label(copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") }
                        Spacer()
                        ShareLink(item: Diagnostics.report(model: model, notif: notif)) { Label("Share", systemImage: "square.and.arrow.up") }
                        Spacer()
                        Button { refresh += 1; Diagnostics.notificationStatus { notif = $0 } } label: { Image(systemName: "arrow.clockwise") }
                    }.buttonStyle(.borderless)
                } footer: { Text("Screenshot this screen (scroll for the rest), or Copy and paste it to us. Lines marked red are the likely problem.") }
                ForEach(secs) { sec in
                    Section(sec.title) {
                        ForEach(sec.rows) { r in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.key).font(.caption2).foregroundStyle(.secondary)
                                Text(r.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(r.bad ? .red : .primary).textSelection(.enabled)
                            }
                        }
                    }
                }
                Section("Log (last 50 lines)") {
                    Text(Log.lines.suffix(50).joined(separator: "\n")).font(.system(size: 9, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).id("log")
                }
            }
            .id(refresh)
            .onAppear {
                Diagnostics.notificationStatus { notif = $0 }
                if let anchor = TestMode.value("debugAnchor") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { proxy.scrollTo(anchor, anchor: .top) } } }
            }
        }
        .navigationTitle("Debug")
    }
}

struct LiveActivityPanel: View {
    @EnvironmentObject var model: PepeModel
    @ObservedObject var la = LiveActivityManager.shared
    @State var tick = 0

    var body: some View {
        let widget = LiveActivityManager.widgetPresent
        Section {
            HStack {
                Button { LiveActivityManager.shared.start(model.liveActivityContent(), reason: "Start tapped"); tick += 1 } label: { Label("Start Live Activity", systemImage: "play.circle") }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button(role: .destructive) { LiveActivityManager.shared.userEnd(); tick += 1 } label: { Label("End", systemImage: "stop.circle") }
                    .buttonStyle(.bordered)
            }
            row("state", la.phase, bad: la.phase.hasPrefix("denied") || la.phase == "disabled")
            row("areActivitiesEnabled", LiveActivityManager.enabled ? "true" : "FALSE (iOS Settings > Pepe > Live Activities)", bad: !LiveActivityManager.enabled)
            row("frequent updates", LiveActivityManager.frequentUpdates ? "true" : "false")
            row("widget", widget ? "present" : "missing", bad: !widget)
            row("install", InstallInfo.kind, bad: InstallInfo.isLiveContainer)
            row("updates sent", "\(la.updatesSent)")
            row("last error", la.lastError.isEmpty ? "none" : la.lastError, bad: !la.lastError.isEmpty)
        } header: { Text("Live Activity") } footer: {
            Text("The Lock Screen / Dynamic Island card is drawn by the widget extension, which is only in the iLoader (or Sideloader) install of the with-widget IPA. LiveContainer cannot run extensions: there the request fails or nothing shows. Test: tap Start, check the state says active, then lock the phone (or swipe home: the Island shows Pepe).")
        }
        .id(tick)
    }

    private func row(_ k: String, _ v: String, bad: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(bad ? .red : .primary).multilineTextAlignment(.trailing)
        }
    }
}
