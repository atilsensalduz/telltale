import Foundation
import Darwin

// MARK: - Probe protocol

/// What the Sampler learned about the network at the start of a tick.
public struct ProbeEnvironment: Equatable, Sendable {
    /// IPv4 default gateway, nil when there is no default route.
    public var gateway: String?
    public var interface: InterfaceKind
    public init(gateway: String?, interface: InterfaceKind) {
        self.gateway = gateway; self.interface = interface
    }
}

public struct ProbeOutput: Sendable {
    public var result: ProbeResult
    public var httpsBreakdown: HTTPSBreakdown?
    public init(_ result: ProbeResult, httpsBreakdown: HTTPSBreakdown? = nil) {
        self.result = result; self.httpsBreakdown = httpsBreakdown
    }
}

public protocol Probe: Sendable {
    var kind: ProbeKind { get }
    func run(_ env: ProbeEnvironment) async -> ProbeOutput
}

/// Runs blocking socket work off the cooperative thread pool.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
    }
}

// MARK: - ICMP

enum ICMPPacket {
    /// 16-byte echo request (8-byte header + 8 bytes payload) with a valid checksum.
    static func echoRequest(id: UInt16, seq: UInt16) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 16)
        p[0] = 8
        p[4] = UInt8(id >> 8); p[5] = UInt8(id & 0xff)
        p[6] = UInt8(seq >> 8); p[7] = UInt8(seq & 0xff)
        let ck = checksum(p)
        p[2] = UInt8(ck >> 8); p[3] = UInt8(ck & 0xff)
        return p
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]); i += 2 }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    /// True if `buf` is an ICMP echo reply. macOS DGRAM sockets deliver the IPv4 header too; it is skipped.
    static func isEchoReply(_ buf: [UInt8]) -> Bool {
        guard let first = buf.first else { return false }
        let off = (first >> 4) == 4 ? Int(first & 0x0f) * 4 : 0
        return buf.count >= off + 8 && buf[off] == 0
    }
}

/// Unprivileged ICMP echo (SOCK_DGRAM). Works with and without the App Sandbox
/// (a sandboxed build would need both network.client and network.server entitlements; Telltale is not sandboxed).
public struct ICMPProbe: Probe {
    public enum Target: Sendable, Equatable {
        case gateway
        case host(String)
    }
    public let kind: ProbeKind
    public let target: Target
    public let timeoutMs: Int32

    public init(kind: ProbeKind, target: Target, timeoutMs: Int32 = 2000) {
        self.kind = kind; self.target = target; self.timeoutMs = timeoutMs
    }

    public func run(_ env: ProbeEnvironment) async -> ProbeOutput {
        let host: String
        switch target {
        case .gateway:
            guard let gw = env.gateway else { return ProbeOutput(.fail) }   // no default route
            host = gw
        case .host(let h): host = h
        }
        let timeout = timeoutMs
        let ms = await runBlocking { Self.ping(host, timeoutMs: timeout) }
        return ProbeOutput(ms.map(ProbeResult.ok) ?? .fail)
    }

    static func ping(_ host: String, timeoutMs: Int32) -> Double? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }

        let pkt = ICMPPacket.echoRequest(id: .random(in: 1...UInt16.max), seq: 1)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent >= 0 else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = t0 + UInt64(timeoutMs) * 1_000_000
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remaining = Int32((deadline - now) / 1_000_000)
            guard poll(&pfd, 1, max(remaining, 1)) > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(fd, &buf, buf.count, 0)
            guard n >= 0 else { return nil }
            if ICMPPacket.isEchoReply(Array(buf.prefix(n))) {
                return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }
        }
    }
}

// MARK: - DNS

enum DNSPacket {
    /// Standard recursive A query for `name`.
    static func query(name: String, id: UInt16) -> [UInt8] {
        var p: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            p.append(UInt8(label.utf8.count))
            p.append(contentsOf: label.utf8)
        }
        p.append(0)
        p.append(contentsOf: [0, 1, 0, 1])   // QTYPE A, QCLASS IN
        return p
    }

    /// True if `buf` is a response (QR bit) carrying our transaction id. Any RCODE counts:
    /// NXDOMAIN still proves the resolver answered.
    static func isResponse(_ buf: [UInt8], id: UInt16) -> Bool {
        guard buf.count >= 12 else { return false }
        return buf[0] == UInt8(id >> 8) && buf[1] == UInt8(id & 0xff) && (buf[2] & 0x80) != 0
    }
}

/// UDP DNS query straight to a public resolver, independent of the system resolver.
public struct DNSProbe: Probe {
    public let kind = ProbeKind.dns
    public let server: String
    public let timeoutMs: Int32
    static let names = ["www.example.com", "www.cloudflare.com", "www.wikipedia.org", "www.apple.com", "www.debian.org"]

    public init(server: String = "1.1.1.1", timeoutMs: Int32 = 2000) {
        self.server = server; self.timeoutMs = timeoutMs
    }

    public func run(_ env: ProbeEnvironment) async -> ProbeOutput {
        let server = server, timeout = timeoutMs
        let name = Self.names.randomElement()!
        let ms = await runBlocking { Self.query(name: name, server: server, timeoutMs: timeout) }
        return ProbeOutput(ms.map(ProbeResult.ok) ?? .fail)
    }

    static func query(name: String, server: String, timeoutMs: Int32) -> Double? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }

        let id = UInt16.random(in: 0...UInt16.max)
        let q = DNSPacket.query(name: name, id: id)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, q, q.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent >= 0 else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = t0 + UInt64(timeoutMs) * 1_000_000
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let remaining = Int32((deadline - now) / 1_000_000)
            guard poll(&pfd, 1, max(remaining, 1)) > 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: 512)
            let n = recv(fd, &buf, buf.count, 0)
            guard n >= 0 else { return nil }
            if DNSPacket.isResponse(Array(buf.prefix(n)), id: id) {
                return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            }
        }
    }
}

// MARK: - HTTPS

/// A fresh HTTPS request on a new connection (own ephemeral session, no cache), like a first browser hit.
/// Uses the system resolver and proxy settings, so it reflects what apps actually experience.
public struct HTTPSProbe: Probe {
    public let kind = ProbeKind.https
    public let url: URL
    public let timeout: TimeInterval

    public init(url: URL = URL(string: "https://www.gstatic.com/generate_204")!, timeout: TimeInterval = 4) {
        self.url = url; self.timeout = timeout
    }

    public func run(_ env: ProbeEnvironment) async -> ProbeOutput {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        cfg.waitsForConnectivity = false
        let collector = MetricsCollector()
        let session = URLSession(configuration: cfg, delegate: collector, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            var req = URLRequest(url: url)
            req.setValue("telltale", forHTTPHeaderField: "User-Agent")
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
                return ProbeOutput(.fail)
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return ProbeOutput(.ok(ms), httpsBreakdown: collector.breakdown())
        } catch {
            return ProbeOutput(.fail)
        }
    }
}

final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    func urlSession(_ s: URLSession, task: URLSessionTask, didFinishCollecting m: URLSessionTaskMetrics) {
        lock.lock(); metrics = m; lock.unlock()
    }

    func breakdown() -> HTTPSBreakdown? {
        lock.lock(); defer { lock.unlock() }
        guard let t = metrics?.transactionMetrics.last else { return nil }
        func ms(_ a: Date?, _ b: Date?) -> Double? {
            guard let a, let b else { return nil }
            return b.timeIntervalSince(a) * 1000
        }
        return HTTPSBreakdown(
            dnsMs: ms(t.domainLookupStartDate, t.domainLookupEndDate),
            tcpMs: ms(t.connectStartDate, t.secureConnectionStartDate ?? t.connectEndDate),
            tlsMs: ms(t.secureConnectionStartDate, t.secureConnectionEndDate),
            ttfbMs: ms(t.requestStartDate, t.responseStartDate))
    }
}
