import Foundation
import Network

/// Local filtering proxy for web wallpapers with internet access.
///
/// The URL block list alone isn't enough: a public name can resolve via DNS to an address on the
/// home network (e.g. "192-168-1-1.nip.io" or DNS rebinding). That's why all connections
/// of web wallpapers go through this proxy. It resolves every name itself, rejects private, local and
/// other non-public addresses and then connects to exactly the checked IP – so changing
/// the name's address later has no effect.
///
/// It only listens on 127.0.0.1 and understands CONNECT (HTTPS/WSS) as well as simple HTTP requests
/// in absolute form ("GET http://host/path").
final class NetGuardProxy: @unchecked Sendable {
    static let shared = NetGuardProxy()

    private let queue = DispatchQueue(label: "local.livebloom.netguard")
    private var listener: NWListener?
    private var readyHandlers: [@Sendable (UInt16?) -> Void] = []
    private var port: UInt16?
    private var failed = false
    private var activeConnections = 0

    /// Limit for simultaneous connections: a wallpaper must not be able to cripple the app with open
    /// connections (each one costs two file descriptors in the app process).
    /// Computed at launch from the descriptor limit and set high enough that WebKit's own
    /// limits (also with several displays) kick in first.
    private var maxConnections = 64
    private static let headerTimeout: TimeInterval = 10

    /// Raises the soft file descriptor limit (default for apps: 256) and derives the
    /// connection limit from it; 256 descriptors stay free for the rest of the app.
    private func raiseDescriptorLimit() {
        var rl = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &rl) == 0 else { return }
        let wanted: rlim_t = 8192
        if rl.rlim_cur < wanted {
            var n = rl
            n.rlim_cur = min(wanted, rl.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &n) == 0 { rl = n }
        }
        let available = Int(min(rl.rlim_cur, 1 << 20)) - 256
        maxConnections = max(64, min(2048, available / 2))
    }

    /// Starts the proxy and reports the port – or nil if it couldn't start.
    /// Only runs while web wallpapers have internet access (see `stop()`).
    func start(_ completion: @escaping @Sendable (UInt16?) -> Void) {
        queue.async { [self] in
            if let port { completion(port); return }
            if failed { completion(nil); return }
            readyHandlers.append(completion)
            guard listener == nil else { return }
            raiseDescriptorLimit()
            do {
                let params = NWParameters.tcp
                params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let l = try NWListener(using: params)
                listener = l
                l.newConnectionHandler = { [weak self] c in self?.accept(c) }
                // Ignore events from a listener that has already been replaced or stopped.
                l.stateUpdateHandler = { [weak self, weak l] state in
                    guard let self, let l, l === self.listener else { return }
                    self.listenerState(state, l)
                }
                l.start(queue: queue)
            } catch {
                NSLog("LiveBloom: filtering proxy could not start: \(error)")
                finishStart(nil)
            }
        }
    }

    private func listenerState(_ state: NWListener.State, _ l: NWListener) {
        switch state {
        case .ready:
            // Never report port 0: in that case the start counts as failed.
            if let p = l.port?.rawValue, p != 0 { finishStart(p) }
            else { l.cancel(); listener = nil; finishStart(nil) }
        case .failed(let e):
            NSLog("LiveBloom: filtering proxy failed: \(e)")
            port = nil
            l.cancel(); listener = nil
            finishStart(nil)
        default: break
        }
    }

    private func finishStart(_ p: UInt16?) {
        port = p
        if p == nil { failed = true }
        let hs = readyHandlers; readyHandlers = []
        hs.forEach { $0(p) }
    }

    /// Stops the proxy (internet access off): no open tunnel for other local programs.
    func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            port = nil; failed = false
            let hs = readyHandlers; readyHandlers = []
            hs.forEach { $0(nil) }
        }
    }

    // MARK: Connections

    private static let maxHeader = 32 * 1024

    /// State per connection (only changed on `queue`): headers complete? Still counted?
    private final class HeaderState { var done = false; var counted = true }

    private func accept(_ client: NWConnection) {
        // Over the limit: answer with "503" instead of closing silently (otherwise WebKit retries endlessly).
        guard activeConnections < maxConnections else {
            client.start(queue: queue)
            return reject(client, "503 Service Unavailable")
        }
        activeConnections += 1
        let hs = HeaderState()
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                if hs.counted { hs.counted = false; self?.activeConnections -= 1 }
                if case .failed = state { client.cancel() }
            default: break
            }
        }
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.headerTimeout) { if !hs.done { client.cancel() } }
        readHeader(client, buffer: Data(), state: hs)
    }

    private func readHeader(_ client: NWConnection, buffer: Data, state: HeaderState) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { client.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                state.done = true
                self.handle(client, head: buf[buf.startIndex..<end.lowerBound], rest: buf[end.upperBound...])
            } else if error != nil || done || buf.count > Self.maxHeader {
                client.cancel()
            } else {
                self.readHeader(client, buffer: buf, state: state)
            }
        }
    }

    private func handle(_ client: NWConnection, head: Data, rest: Data) {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return reject(client, "400 Bad Request")
        }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return reject(client, "400 Bad Request") }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])

        if method.uppercased() == "CONNECT" {
            guard let (host, port) = Self.splitHostPort(target, defaultPort: nil) else { return reject(client, "400 Bad Request") }
            open(client, host: host, port: port) { upstream in
                let ok = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                client.send(content: ok, completion: .contentProcessed { _ in
                    if !rest.isEmpty { upstream.send(content: rest, completion: .idempotent) }
                    self.pipe(client, upstream)
                })
            }
            return
        }

        // Simple HTTP request in absolute form; only http, https always goes through CONNECT.
        guard let url = URLComponents(string: target), url.scheme?.lowercased() == "http",
              let rawHost = url.percentEncodedHost, !rawHost.isEmpty else { return reject(client, "400 Bad Request") }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        // UInt16(exactly:): URLComponents also accepts ports above 65535, UInt16(_:) would crash.
        guard let port = UInt16(exactly: url.port ?? 80), port > 0 else { return reject(client, "400 Bad Request") }
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let q = url.percentEncodedQuery { path += "?" + q }

        // Headers: remove proxy-specific ones. Without an upgrade (WebSocket), close the connection after the
        // response so that another request on the same connection can't go to a
        // different, unchecked host.
        let isUpgrade = lines.contains { $0.lowercased().hasPrefix("upgrade:") }
        var out = ["\(method) \(path) \(version)"]
        for l in lines where !l.isEmpty {
            let name = l.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            if name.hasPrefix("proxy-") || name == "keep-alive" { continue }
            if name == "connection" && !isUpgrade { continue }
            out.append(l)
        }
        if !isUpgrade { out.append("Connection: close") }
        let request = Data((out.joined(separator: "\r\n") + "\r\n\r\n").utf8) + rest

        open(client, host: host, port: port) { upstream in
            upstream.send(content: request, completion: .contentProcessed { _ in self.pipe(client, upstream) })
        }
    }

    /// Resolve names, check addresses and connect to the checked IP.
    private func open(_ client: NWConnection, host: String, port: UInt16, then: @escaping (NWConnection) -> Void) {
        guard port > 0, !host.contains("%") else { return reject(client, "400 Bad Request") }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let addrs = Self.resolve(host)
            queue.async { [self] in
                // As soon as even one address isn't public – or belongs to the Mac itself or to one of
                // its directly attached networks (e.g. a global IPv6 on the home network) – the request is rejected.
                let local = Self.localNetworks()
                guard !addrs.isEmpty,
                      addrs.allSatisfy({ Self.isPublic($0) && !Self.isLocal($0, local) }) else {
                    return reject(client, "403 Forbidden")
                }
                connect(client, to: addrs, port: port, then: then)
            }
        }
    }

    /// Connect to the (already checked) addresses one after another – like a browser falls back
    /// to IPv4 when IPv6 is broken. Only if none works is there a "502".
    private func connect(_ client: NWConnection, to addrs: [Data], port: UInt16, then: @escaping (NWConnection) -> Void) {
        guard let a = addrs.first else { return reject(client, "502 Bad Gateway") }
        let ip: NWEndpoint.Host = a.count == 4 ? .ipv4(IPv4Address(a)!) : .ipv6(IPv6Address(a)!)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = addrs.count > 1 ? 5 : 15
        let upstream = NWConnection(host: ip, port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        final class Phase { var value = 0 }   // 0 = connecting, 1 = connected, 2 = given up (only on `queue`)
        let phase = Phase()
        upstream.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready where phase.value == 0:
                phase.value = 1
                then(upstream)
            case .failed, .waiting:
                if phase.value == 0 {
                    phase.value = 2
                    upstream.cancel()
                    self?.connect(client, to: Array(addrs.dropFirst()), port: port, then: then)
                } else if phase.value == 1 {
                    upstream.cancel(); client.cancel()
                }
            case .cancelled:
                if phase.value == 1 { client.cancel() }   // cancelled failed attempts leave the client open
            default: break
            }
        }
        upstream.start(queue: queue)
    }

    private func reject(_ client: NWConnection, _ status: String) {
        let resp = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        client.send(content: resp, completion: .contentProcessed { _ in client.cancel() })
    }

    /// Pass data in both directions; once both directions are done (or there is an
    /// error), both connections are closed.
    private func pipe(_ a: NWConnection, _ b: NWConnection) {
        var openDirections = 2   // only changed on `queue`
        func closeAll() { a.cancel(); b.cancel() }
        func finished(_ to: NWConnection) {
            // Half-close: the other direction may still finish sending its response.
            to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            openDirections -= 1
            if openDirections == 0 { closeAll() }
        }
        func forward(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, done, error in
                if error != nil { closeAll(); return }
                if let data, !data.isEmpty {
                    to.send(content: data, completion: .contentProcessed { err in
                        if err != nil { closeAll() } else if done { finished(to) } else { forward(from, to) }
                    })
                } else if done {
                    finished(to)
                } else {
                    forward(from, to)
                }
            }
        }
        forward(a, b)
        forward(b, a)
    }

    // MARK: Helpers (static so they can be tested)

    /// Split "host:port" or "[v6]:port".
    static func splitHostPort(_ s: String, defaultPort: UInt16?) -> (String, UInt16)? {
        var host = s, portStr: Substring?
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { return nil }
            host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") { portStr = after.dropFirst() } else if !after.isEmpty { return nil }
        } else if let colon = s.lastIndex(of: ":") {
            host = String(s[..<colon]); portStr = s[s.index(after: colon)...]
        }
        guard !host.isEmpty else { return nil }
        if let portStr { guard let p = UInt16(portStr), p > 0 else { return nil }; return (host, p) }
        guard let d = defaultPort else { return nil }
        return (host, d)
    }

    /// All addresses of a name (or the IP literal itself) as raw bytes (4 or 16 bytes).
    static func resolve(_ host: String) -> [Data] {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return [withUnsafeBytes(of: &v4) { Data($0) }] }
        if inet_pton(AF_INET6, host, &v6) == 1 { return [withUnsafeBytes(of: &v6) { Data($0) }] }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [] }
        defer { freeaddrinfo(first) }
        var out: [Data] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if let sa = ai.pointee.ai_addr {
                if ai.pointee.ai_family == AF_INET {
                    sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var a = $0.pointee.sin_addr; out.append(withUnsafeBytes(of: &a) { Data($0) }) }
                } else if ai.pointee.ai_family == AF_INET6 {
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { var a = $0.pointee.sin6_addr; out.append(withUnsafeBytes(of: &a) { Data($0) }) }
                }
            }
            p = ai.pointee.ai_next
        }
        return out
    }

    /// The Mac's own addresses with netmask (all interfaces, read fresh on every call).
    static func localNetworks() -> [(addr: [UInt8], mask: [UInt8])] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(first) }
        func bytes(_ sa: UnsafeMutablePointer<sockaddr>?) -> [UInt8]? {
            guard let sa else { return nil }
            switch Int32(sa.pointee.sa_family) {
            case AF_INET:
                return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { var a = $0.pointee.sin_addr; return withUnsafeBytes(of: &a) { Array($0) } }
            case AF_INET6:
                return sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { var a = $0.pointee.sin6_addr; return withUnsafeBytes(of: &a) { Array($0) } }
            default: return nil
            }
        }
        var out: [(addr: [UInt8], mask: [UInt8])] = []
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            if let a = bytes(ifa.pointee.ifa_addr) {
                let m = bytes(ifa.pointee.ifa_netmask) ?? [UInt8](repeating: 0xff, count: a.count)
                out.append((a, m.count == a.count ? m : [UInt8](repeating: 0xff, count: a.count)))
            }
            p = ifa.pointee.ifa_next
        }
        return out
    }

    /// true if the address is one of the Mac's own or lies in one of its attached networks.
    /// A mask of 0 (default route) doesn't count as an attached network.
    static func isLocal(_ a: Data, _ nets: [(addr: [UInt8], mask: [UInt8])]) -> Bool {
        let b = [UInt8](a)
        for n in nets where n.addr.count == b.count {
            if n.addr == b { return true }
            guard n.mask.contains(where: { $0 != 0 }) else { continue }
            if zip(zip(b, n.addr), n.mask).allSatisfy({ ($0.0 & $1) == ($0.1 & $1) }) { return true }
        }
        return false
    }

    /// true only for publicly routable addresses.
    static func isPublic(_ a: Data) -> Bool {
        let b = [UInt8](a)
        if b.count == 4 { return isPublicV4(b) }
        guard b.count == 16 else { return false }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }                         // :: and ::1
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {      // ::ffff:a.b.c.d
            return isPublicV4(Array(b[12..<16]))
        }
        if b[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublicV4(Array(b[12..<16])) } // NAT64
        if b[0..<6] == [0, 0x64, 0xff, 0x9b, 0, 0x01] { return false }                   // 64:ff9b:1::/48 (local NAT64)
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicV4(Array(b[2..<6])) }       // 6to4
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0 && b[3] == 0 { return false }   // Teredo
        if b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8 { return false } // Documentation
        if b[0] == 0x01 && b[1] == 0 && b[2..<8].allSatisfy({ $0 == 0 }) { return false } // 100::/64
        if b[0] & 0xfe == 0xfc { return false }                                       // fc00::/7 (ULA)
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }                       // fe80::/10
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }                       // fec0::/10
        if b[0] == 0xff { return false }                                              // Multicast
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }                         // ::a.b.c.d (deprecated)
        return true
    }

    static func isPublicV4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false                // Carrier-grade NAT / Tailscale
        case (169, 254, _): return false                     // Link-local
        case (172, 16...31, _): return false
        case (192, 168, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 88, 99): return false
        case (198, 18...19, _): return false                 // Benchmarking network
        case (198, 51, 100), (203, 0, 113): return false     // Documentation
        case (224...255, _, _): return false                 // Multicast, reserved, broadcast
        default: return true
        }
    }
}
