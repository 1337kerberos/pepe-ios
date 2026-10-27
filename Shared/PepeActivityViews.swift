// Live Activity content views shared by the widget extension (Lock Screen + Dynamic Island) and the app (0.16: the
// in-app Lock Screen preview in Settings > Live Activity, and the same question card on the main screen).
import SwiftUI
import AppIntents

struct LockScreenView: View {
    let state: PepeActivityAttributes.ContentState
    var body: some View {
        if let ask = state.ask {
            AskLockView(ask: ask, more: state.asksWaiting - 1)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    SpriteView(state: state.state, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Pepe: \(PepeStateStyle.label(state.state))").font(.headline).foregroundStyle(.white)
                            if let ok = state.ok { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red).font(.caption) }
                            Spacer()
                            Text(state.updatedAt, style: .time).font(.caption2).foregroundStyle(.white.opacity(0.5))
                        }
                        Text(state.line).font(.subheadline).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                        if !state.tool.isEmpty { Text(state.tool).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.5)).lineLimit(1) }
                        if state.agentsTotal > 0 {
                            HStack(spacing: 6) {
                                AgentDots(states: state.agentStates)
                                Text("\(state.agentsWorking) of \(state.agentsTotal) agents working").font(.caption2).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                }
                ButtonsRow()
            }
            .padding(14)
        }
    }
}

struct ButtonsRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Button(intent: PepeSummaryIntent()) { Label("Summary", systemImage: "text.bubble") }
            Button(intent: PepeWhereIntent()) { Label("Where", systemImage: "location") }
        }
        .buttonStyle(.bordered).tint(.green).font(.caption.bold())
    }
}

/// 0.16: seconds left on a pending ask; a live timer (the system ticks it, no updates needed). Never builds an inverted
/// range (that traps), an expired ask shows 0:00.
struct AskCountdown: View {
    let expires: Date
    var body: some View {
        let now = Date()
        if expires > now.addingTimeInterval(0.5) {
            Text(timerInterval: now...expires, countsDown: true, showsHours: false).monospacedDigit().multilineTextAlignment(.trailing)
        } else {
            Text("0:00").monospacedDigit()
        }
    }
}

/// Allow / Deny as LiveActivityIntents: they run in the app's process (woken in the background if needed), which sends
/// {"type":"ask_answer"} on its brain socket. After a tap the card says what was sent until the brain resolves it.
struct AskButtons: View {
    let ask: PepeAsk
    var height: CGFloat = 34
    var body: some View {
        if ask.sent.isEmpty {
            HStack(spacing: 10) {
                Button(intent: PepeAskAnswerIntent(askId: ask.id, answer: "allow")) {
                    Label("Allow", systemImage: "checkmark").foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: height - 14)
                }.tint(.green)
                Button(intent: PepeAskAnswerIntent(askId: ask.id, answer: "deny")) {
                    Label("Deny", systemImage: "xmark").foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: height - 14)
                }.tint(.red)
            }
            .buttonStyle(.borderedProminent).font(.subheadline.bold())
        } else {
            HStack(spacing: 6) {
                Image(systemName: ask.sent == "allow" ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ask.sent == "allow" ? .green : .red)
                Text(ask.sent == "allow" ? "Allowed, sending…" : "Denied, sending…").font(.subheadline.bold()).foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity, minHeight: height)
        }
    }
}

/// Lock Screen while a question waits: sprite, "needs your OK", who asks, the question, countdown, Allow / Deny.
struct AskLockView: View {
    let ask: PepeAsk
    var more: Int = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                SpriteView(state: "waiting", size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).symbolEffect(.pulse, options: .repeating)
                        Text("Needs your OK").font(.headline).foregroundStyle(.white).lineLimit(1)
                        Spacer(minLength: 4)
                        AskCountdown(expires: ask.expires).font(.caption.bold()).foregroundStyle(.orange).frame(width: 46, alignment: .trailing)
                    }
                    Text(ask.source + (more > 0 ? "  +\(more) more" : "")).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    Text(ask.shortText).font(.subheadline).foregroundStyle(.white.opacity(0.92)).lineLimit(2).minimumScaleFactor(0.85)
                }
            }
            AskButtons(ask: ask)
        }
        .padding(14)
    }
}
