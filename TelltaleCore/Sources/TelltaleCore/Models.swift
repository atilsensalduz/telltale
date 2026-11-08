import Foundation

/// Which kind of interface carries the default route for a sample.
public enum InterfaceKind: String, Codable, Sendable, CaseIterable {
    case wifi, ethernet, vpn, other
}

/// Outcome of one probe in one tick.
public enum ProbeResult: Equatable, Codable, Sendable {
    /// Succeeded; latency in milliseconds.
    case ok(Double)
    /// Ran and failed (timeout, error).
    case fail
    /// Could not be evaluated (e.g. no Wi-Fi interface). Never counts as an outage.
    case unavailable

    public var latency: Double? {
        if case .ok(let ms) = self { return ms }
        return nil
    }
    public var isFail: Bool { self == .fail }
}

/// The probes that carry a latency and take part in diagnosis.
public enum ProbeKind: String, Codable, Sendable, CaseIterable {
    case gateway, cloudflare, google, dns, https
}

public struct HTTPSBreakdown: Equatable, Codable, Sendable {
    public var dnsMs: Double?
    public var tcpMs: Double?
    public var tlsMs: Double?
    public var ttfbMs: Double?
    public init(dnsMs: Double? = nil, tcpMs: Double? = nil, tlsMs: Double? = nil, ttfbMs: Double? = nil) {
        self.dnsMs = dnsMs; self.tcpMs = tcpMs; self.tlsMs = tlsMs; self.ttfbMs = ttfbMs
    }
}

/// CoreWLAN stats. No SSID by design (no Location permission).
public struct WifiStats: Equatable, Codable, Sendable {
    public var rssi: Int
    public var noise: Int
    public var channel: Int
    public var txRateMbps: Double
    public var snr: Int { rssi - noise }
    public init(rssi: Int, noise: Int, channel: Int, txRateMbps: Double) {
        self.rssi = rssi; self.noise = noise; self.channel = channel; self.txRateMbps = txRateMbps
    }
}

/// One tick of all probes.
public struct Sample: Equatable, Codable, Sendable {
    public var ts: Date
    public var interface: InterfaceKind
    public var gateway: ProbeResult
    public var cloudflare: ProbeResult
    public var google: ProbeResult
    public var dns: ProbeResult
    public var https: ProbeResult
    public var httpsBreakdown: HTTPSBreakdown?
    public var wifi: WifiStats?

    public init(ts: Date, interface: InterfaceKind = .wifi,
                gateway: ProbeResult, cloudflare: ProbeResult, google: ProbeResult,
                dns: ProbeResult, https: ProbeResult,
                httpsBreakdown: HTTPSBreakdown? = nil, wifi: WifiStats? = nil) {
        self.ts = ts; self.interface = interface
        self.gateway = gateway; self.cloudflare = cloudflare; self.google = google
        self.dns = dns; self.https = https
        self.httpsBreakdown = httpsBreakdown; self.wifi = wifi
    }

    public subscript(kind: ProbeKind) -> ProbeResult {
        switch kind {
        case .gateway: return gateway
        case .cloudflare: return cloudflare
        case .google: return google
        case .dns: return dns
        case .https: return https
        }
    }
}

/// Where the problem is. Raw values are the display strings.
public enum Cause: String, Codable, Sendable, CaseIterable {
    case localNetwork = "Local network (Wi-Fi/router)"
    case isp = "ISP / upstream"
    case dns = "DNS"
    case webPath = "Web path (HTTPS/proxy/VPN/site)"
}

public enum DegradeReason: Equatable, Codable, Sendable {
    case loss(ProbeKind)
    case highLatency(ProbeKind)
}

public enum Status: Equatable, Codable, Sendable {
    case healthy
    case degraded([DegradeReason])
    case outage(Cause)
}

public struct Diagnosis: Equatable, Codable, Sendable {
    public var status: Status
    /// Start of the current non-healthy run; nil when healthy.
    public var since: Date?
    /// Router never answered ICMP while the internet was reachable, so rule 1 is skipped.
    public var gatewayIcmpBlocked: Bool

    public init(status: Status, since: Date?, gatewayIcmpBlocked: Bool) {
        self.status = status; self.since = since; self.gatewayIcmpBlocked = gatewayIcmpBlocked
    }
}
