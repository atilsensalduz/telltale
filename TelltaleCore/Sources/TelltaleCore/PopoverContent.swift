import Foundation

public enum LayerHealth: Equatable, Sendable {
    case ok
    /// The Diagnoser reports this layer as lossy or slow.
    case slow
    /// The latest probe failed.
    case failing
    case unavailable
}

/// One bucket of a sparkline.
public enum SparkPoint: Equatable, Sendable {
    /// Highest latency in the bucket, in ms.
    case value(Double)
    /// At least one probe failed in the bucket.
    case failure
    /// No data in the bucket.
    case gap
}

public struct LayerRow: Equatable, Sendable, Identifiable {
    public var id: ProbeKind { kind }
    public var kind: ProbeKind
    public var valueText: String
    public var health: LayerHealth
    public var points: [SparkPoint]
}

public struct Banner: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case neutral, healthy, degraded, outage }
    public var style: Style
    public var title: String
    public var subtitle: String
    /// Extra caveat, e.g. the router ignoring ping.
    public var note: String?
}

public struct ChartPoint: Equatable, Sendable, Identifiable {
    public var id: Date { ts }
    public var ts: Date
    public var ms: Double
    /// Points in the same segment are joined by a line; a failed probe starts a new segment.
    public var segment: Int
}

public struct HTTPSChart: Equatable, Sendable {
    public var points: [ChartPoint]
    /// Timestamps of failed HTTPS probes, drawn as red marks.
    public var failures: [Date]
    public var start: Date
    public var end: Date
}

/// Everything the popover shows, as plain values so it can be unit-tested without a UI.
public enum PopoverContent {
    // MARK: Layer rows

    /// One row per probe, from the newest sample and the last `span` seconds of history.
    public static func rows(samples: [Sample], diagnosis: Diagnosis?,
                            span: TimeInterval = 1800, buckets: Int = 60) -> [LayerRow] {
        let latest = samples.last
        var flagged: Set<ProbeKind> = []
        if case .degraded(let reasons)? = diagnosis?.status {
            for r in reasons {
                switch r { case .loss(let k), .highLatency(let k): flagged.insert(k) }
            }
        }
        return ProbeKind.allCases.map { kind in
            let result = latest?[kind] ?? .unavailable
            let health: LayerHealth
            switch result {
            case .unavailable: health = .unavailable
            case .fail: health = .failing
            case .ok: health = flagged.contains(kind) ? .slow : .ok
            }
            return LayerRow(kind: kind, valueText: valueText(result), health: health,
                            points: sparkline(samples, kind: kind, span: span, buckets: buckets))
        }
    }

    static func valueText(_ r: ProbeResult) -> String {
        switch r {
        case .ok(let ms): return ms >= 1000 ? String(format: "%.1f s", ms / 1000) : "\(Int(ms.rounded())) ms"
        case .fail: return "fail"
        case .unavailable: return "n/a"
        }
    }

    /// `buckets` equal slices of the `span` seconds ending at the newest sample.
    /// A bucket shows its highest latency, or a failure if any probe in it failed.
    static func sparkline(_ samples: [Sample], kind: ProbeKind, span: TimeInterval, buckets: Int) -> [SparkPoint] {
        guard let end = samples.last?.ts, buckets > 0 else { return Array(repeating: .gap, count: max(buckets, 0)) }
        let start = end.addingTimeInterval(-span)
        let width = span / Double(buckets)
        var peak = [Double?](repeating: nil, count: buckets)
        var failed = [Bool](repeating: false, count: buckets)
        var seen = [Bool](repeating: false, count: buckets)
        for s in samples where s.ts > start {
            let i = min(buckets - 1, max(0, Int((s.ts.timeIntervalSince(start) / width).rounded(.up)) - 1))
            switch s[kind] {
            case .ok(let ms): seen[i] = true; peak[i] = max(peak[i] ?? 0, ms)
            case .fail: seen[i] = true; failed[i] = true
            case .unavailable: break
            }
        }
        return (0..<buckets).map { i in
            if !seen[i] { return .gap }
            if failed[i] { return .failure }
            return .value(peak[i] ?? 0)
        }
    }

    // MARK: Chart and connection line

    /// HTTPS latency over the last `span` seconds, ending at the newest sample.
    public static func httpsChart(samples: [Sample], span: TimeInterval = 1800) -> HTTPSChart {
        guard let end = samples.last?.ts else {
            let now = Date()
            return HTTPSChart(points: [], failures: [], start: now.addingTimeInterval(-span), end: now)
        }
        let start = end.addingTimeInterval(-span)
        var points: [ChartPoint] = []
        var failures: [Date] = []
        var segment = 0
        for s in samples where s.ts >= start {
            switch s.https {
            case .ok(let ms): points.append(ChartPoint(ts: s.ts, ms: ms, segment: segment))
            case .fail: failures.append(s.ts); segment += 1
            case .unavailable: break
            }
        }
        return HTTPSChart(points: points, failures: failures, start: start, end: end)
    }

    /// One line about the link carrying the traffic: Wi-Fi stats, or why there are none.
    public static func connectionLine(_ sample: Sample?) -> String? {
        guard let sample else { return nil }
        switch sample.interface {
        case .wifi:
            guard let w = sample.wifi else { return "Wi-Fi: no signal data" }
            return "Wi-Fi: channel \(w.channel), \(w.rssi) dBm, SNR \(w.snr) dB, \(Int(w.txRateMbps.rounded())) Mbps"
        case .ethernet:
            return "Using Ethernet. Wi-Fi isn't carrying your traffic."
        case .vpn:
            return "Using a VPN. Measurements cover the tunnel, not your Wi-Fi."
        case .other:
            return "Using an unrecognized connection."
        }
    }

    // MARK: Banner

    public static func banner(
        diagnosis: Diagnosis?, now: Date,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
    ) -> Banner {
        guard let diagnosis else {
            return Banner(style: .neutral, title: "Starting…", subtitle: "Waiting for the first measurements.", note: nil)
        }
        let note = diagnosis.gatewayIcmpBlocked
            ? "Your router doesn't answer ping, so the Router row is informational only." : nil
        let since = diagnosis.since
        let sinceText = since.map { " since \(time($0))" } ?? ""
        let soFar = since.map { " \(durationText(now.timeIntervalSince($0))) so far." } ?? ""

        switch diagnosis.status {
        case .healthy:
            return Banner(style: .healthy, title: "All good",
                          subtitle: "Every layer is responding normally.", note: note)
        case .degraded(let reasons):
            let title: String
            switch reasons.first {
            case .loss(let k)?: title = "\(k.displayName) is dropping packets"
            case .highLatency(let k)?: title = "\(k.displayName) is slower than usual"
            case nil: title = "Quality dropped"
            }
            return Banner(style: .degraded, title: title,
                          subtitle: "Not an outage yet.\(soFar)", note: note)
        case .outage(let cause):
            return Banner(style: .outage, title: "\(cause.rawValue) failing\(sinceText)",
                          subtitle: "\(evidence(for: cause))\(soFar)", note: note)
        }
    }

    /// What the probes show for each cause, in plain words.
    public static func evidence(for cause: Cause) -> String {
        switch cause {
        case .localNetwork: return "Your router isn't answering."
        case .isp: return "The router answers, but 1.1.1.1 and 8.8.8.8 don't."
        case .dns: return "Pings work, but DNS queries fail."
        case .webPath: return "Pings and DNS work, but HTTPS requests fail."
        }
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "under a minute" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) h" : "\(h) h \(r) min"
    }
}
