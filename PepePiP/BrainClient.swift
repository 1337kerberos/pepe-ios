// WebSocket client for brain/pepe_brain.py: JSON per message, auto-reconnect with backoff, 20 s pings.
import Foundation

final class BrainClient: NSObject, URLSessionWebSocketDelegate {
    var onEvent: (([String: Any]) -> Void)?
    var onConnection: ((Bool) -> Void)?
    /// brain clock - phone clock, from `hello.clock` (unix seconds); `synced` when the brain says `sync: true`
    private(set) var clockOffset: TimeInterval = 0
    private(set) var synced = false
    func brainNow() -> TimeInterval { Date().timeIntervalSince1970 + clockOffset }

    private let url: URL
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var backoff: TimeInterval = 1
    private var pingTimer: Timer?

    init(url: URL) { self.url = url }

    func connect() {
        guard !closed else { return }
        task?.cancel()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(on: t)
    }

    func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { error in if let error { Log.add("ws send: \(error.localizedDescription)") } }
    }

    func close() {
        closed = true
        pingTimer?.invalidate()
        task?.cancel(with: .normalClosure, reason: nil)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self, self.task === t else { return }
            switch result {
            case .failure(let error):
                Log.add("ws closed: \(error.localizedDescription)")
                self.dropped()
            case .success(let message):
                var data: Data?
                if case .string(let s) = message { data = s.data(using: .utf8) }
                if case .data(let d) = message { data = d }
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if (obj["type"] as? String) == "hello" {
                        if let clock = obj["clock"] as? Double {
                            self.clockOffset = clock - Date().timeIntervalSince1970
                            self.synced = (obj["sync"] as? Bool) ?? false
                            Log.add(String(format: "hello: brain clock offset %+.3f s, sync %@", self.clockOffset, self.synced ? "on" : "off"))
                        } else { self.synced = false }
                    }
                    self.onEvent?(obj)
                }
                self.receive(on: t)
            }
        }
    }

    private func dropped() {
        DispatchQueue.main.async { self.pingTimer?.invalidate() }
        onConnection?(false)
        guard !closed else { return }
        let delay = backoff
        backoff = min(backoff * 2, 15)
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol proto: String?) {
        backoff = 1
        Log.add("ws open \(url)")
        onConnection?(true)
        DispatchQueue.main.async {
            self.pingTimer?.invalidate()
            self.pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
                self?.task?.sendPing { error in if let error { Log.add("ping: \(error.localizedDescription)") } }
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Log.add("ws close code \(closeCode.rawValue)")
        dropped()
    }
}
