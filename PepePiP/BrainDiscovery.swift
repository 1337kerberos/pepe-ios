// Zero-config brain discovery: the brain advertises `_pepe._tcp` (port 8777) via Bonjour/avahi; we browse with NWBrowser
// and resolve the first service to an IPv4 host:port by opening a throwaway NWConnection and reading its remote endpoint
// (NWBrowser itself does not hand out addresses). Needs NSBonjourServices + NSLocalNetworkUsageDescription in Info.plist.
import Foundation
import Network

final class BrainDiscovery {
    var onFound: ((String, Int) -> Void)?
    private var browser: NWBrowser?
    private var probe: NWConnection?
    private var resolving = false
    private(set) var found: (host: String, port: Int)?

    func start() {
        stop()
        let b = NWBrowser(for: .bonjour(type: "_pepe._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { state in
            switch state {
            case .failed(let e): Log.add("discovery: browser failed \(e)")
            case .ready: Log.add("discovery: browsing _pepe._tcp")
            default: break
            }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if results.isEmpty { Log.add("discovery: no _pepe._tcp service on this network"); return }
            for r in results {
                if case .service(let name, _, let domain, _) = r.endpoint { Log.add("discovery: service '\(name)' in \(domain)") }
            }
            if let first = results.first, !self.resolving { self.resolve(first.endpoint) }
        }
        browser = b
        b.start(queue: .main)
    }

    func stop() { browser?.cancel(); browser = nil; probe?.cancel(); probe = nil; resolving = false }

    private func resolve(_ endpoint: NWEndpoint) {
        resolving = true
        let params = NWParameters.tcp
        params.prohibitedInterfaceTypes = [.cellular]
        let c = NWConnection(to: endpoint, using: params)
        probe = c
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = c.currentPath, case .hostPort(let host, let port) = path.remoteEndpoint ?? endpoint {
                    var h: String? = nil
                    if case .ipv4(let a) = host { h = "\(a)" }
                    else if case .ipv6(let a) = host, let v4 = a.asIPv4 { h = "\(v4)" }
                    else if case .name(let n, _) = host { h = n }
                    if let h {
                        let hostOnly = h.split(separator: "%").first.map(String.init) ?? h   // strip %en0 scope ids
                        self.found = (hostOnly, Int(port.rawValue))
                        Log.add("discovery: brain at \(hostOnly):\(port.rawValue)")
                        self.onFound?(hostOnly, Int(port.rawValue))
                    } else { Log.add("discovery: resolved to a non-IPv4 endpoint \(host)") }
                }
                c.cancel(); self.resolving = false
            case .failed(let e):
                Log.add("discovery: resolve failed \(e)"); c.cancel(); self.resolving = false
            case .cancelled: self.resolving = false
            default: break
            }
        }
        c.start(queue: .main)
    }
}
