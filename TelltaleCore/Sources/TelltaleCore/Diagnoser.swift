import Foundation

public struct DiagnoserConfig: Sendable {
    /// Samples considered for outage hysteresis.
    public var window = 5
    /// Failing samples (in `window`) needed to declare an outage.
    public var enterThreshold = 3
    /// An outage clears when failing samples in the window drop to this or fewer.
    public var exitThreshold = 1
    /// Minimum samples in the window before an outage may clear (guards short windows after a path change).
    public var minSamplesToClear = 3

    /// Span used to judge loss.
    public var degradeWindow: TimeInterval = 30
    public var lossThreshold = 0.02
    /// Deviation from the plan (loss > 2%): ignore a single lost sample, which at 5s cadence would always trip it.
    public var minLossSamples = 2
    /// Median of recent latencies must exceed baseline p95 by this multiple...
    public var latencyMultiple = 3.0
    /// ...and by at least this many ms, so 1ms -> 4ms on the router is not an alarm.
    public var latencyFloorMs = 50.0
    public var recentLatencySamples = 5
    /// Healthy samples needed in a baseline before latency degradation is judged.
    public var baselineMinSamples = 60
    public var baselineCapacity = 720

    /// Consecutive samples with gateway failing and internet reachable before declaring the router ICMP-blocked.
    public var blockedAfter = 10

    public init() {}
}

/// Turns a stream of samples into a diagnosis. Pure state machine: no clock, no I/O.
/// Time comes only from `Sample.ts`, so replaying samples is deterministic.
public struct Diagnoser: Sendable {
    public private(set) var config: DiagnoserConfig

    private var lastInterface: InterfaceKind?
    private var recent: [(sample: Sample, cause: Cause?)] = []   // outage window
    private var timed: [Sample] = []                             // degrade window, by time
    /// The last `recentLatencySamples` samples regardless of age, for judging latency. Kept apart from `timed`
    /// because that is limited to 30 s, which at the 30 s cadence would hold two samples at most.
    private var latencyRecent: [Sample] = []
    private var baselines: [InterfaceKind: [ProbeKind: [Double]]] = [:]
    private var blockedStreak = 0
    private var gatewayBlocked = false
    private var outage: (cause: Cause, since: Date)?
    private var degradedSince: Date?

    public init(config: DiagnoserConfig = DiagnoserConfig()) {
        self.config = config
    }

    public mutating func ingest(_ s: Sample) -> Diagnosis {
        // A path change makes earlier samples misleading; start fresh windows but keep any active outage.
        if let last = lastInterface, last != s.interface {
            recent.removeAll(); timed.removeAll(); latencyRecent.removeAll()
            blockedStreak = 0; gatewayBlocked = false
        }
        lastInterface = s.interface

        updateGatewayBlocked(s)

        // Deviation from netwatch.py: a gateway ping that fails while a public target answered in the same
        // sample cannot mean the local network is down (that traffic crosses the router), so rule 1 is
        // skipped. This avoids a false "Local network" outage on routers that drop or rate-limit ICMP.
        let internetOk = s.cloudflare.latency != nil || s.google.latency != nil
        let cause = Rules.classify(s, skipGateway: gatewayBlocked || internetOk)
        recent.append((s, cause))
        if recent.count > config.window { recent.removeFirst(recent.count - config.window) }
        timed.append(s)
        timed.removeAll { s.ts.timeIntervalSince($0.ts) > config.degradeWindow }
        latencyRecent.append(s)
        if latencyRecent.count > config.recentLatencySamples {
            latencyRecent.removeFirst(latencyRecent.count - config.recentLatencySamples)
        }

        let hadOutage = outage != nil
        updateOutage()
        // Failures during an outage must not paint the recovery as "degraded" for the next 30s.
        if hadOutage && outage == nil { timed = [s] }

        let status: Status
        let since: Date?
        if let o = outage {
            degradedSince = nil
            status = .outage(o.cause); since = o.since
        } else {
            let reasons = degradeReasons(for: s)
            if reasons.isEmpty {
                degradedSince = nil
                status = .healthy; since = nil
                addToBaseline(s)
            } else {
                if degradedSince == nil { degradedSince = s.ts }
                status = .degraded(reasons); since = degradedSince
            }
        }
        return Diagnosis(status: status, since: since, gatewayIcmpBlocked: gatewayBlocked)
    }

    /// Forget everything that depends on continuous observation: windows, any outage, the ICMP-blocked state.
    /// Baselines are kept. Call after a gap in sampling (sleep, user pause) so stale failures are not combined
    /// with new samples and a stale outage is not carried across the gap.
    public mutating func resetAfterGap() {
        recent.removeAll(); timed.removeAll(); latencyRecent.removeAll()
        blockedStreak = 0; gatewayBlocked = false
        outage = nil; degradedSince = nil
        lastInterface = nil
    }

    /// Baseline 95th percentile for a probe on an interface, or nil until enough healthy samples exist.
    public func baselineP95(_ interface: InterfaceKind, _ kind: ProbeKind) -> Double? {
        guard let xs = baselines[interface]?[kind], xs.count >= config.baselineMinSamples else { return nil }
        return Self.percentile(xs, 0.95)
    }

    // MARK: - Outage hysteresis

    private mutating func updateOutage() {
        let failing = recent.filter { $0.cause != nil }
        if outage == nil {
            guard failing.count >= config.enterThreshold, let first = failing.first else { return }
            outage = (Self.dominantCause(failing.compactMap(\.cause)), first.sample.ts)
        } else if failing.count <= config.exitThreshold && recent.count >= config.minSamplesToClear {
            outage = nil
        } else if !failing.isEmpty {
            outage?.cause = Self.dominantCause(failing.compactMap(\.cause))
        }
    }

    /// Most frequent cause; ties go to the earlier rule (closer to the user).
    static func dominantCause(_ causes: [Cause]) -> Cause {
        var best = causes[0]
        var bestCount = 0
        for c in Cause.allCases {
            let n = causes.filter { $0 == c }.count
            if n > bestCount { best = c; bestCount = n }
        }
        return best
    }

    // MARK: - ICMP-blocked router

    private mutating func updateGatewayBlocked(_ s: Sample) {
        if s.gateway.latency != nil {
            blockedStreak = 0; gatewayBlocked = false
            return
        }
        let internetOk = s.cloudflare.latency != nil || s.google.latency != nil
        if s.gateway.isFail && internetOk {
            blockedStreak += 1
            if blockedStreak >= config.blockedAfter { gatewayBlocked = true }
        } else if !gatewayBlocked {
            blockedStreak = 0
        }
    }

    // MARK: - Degraded

    private func degradeReasons(for s: Sample) -> [DegradeReason] {
        var reasons: [DegradeReason] = []
        for kind in ProbeKind.allCases {
            if kind == .gateway && gatewayBlocked { continue }
            let results = timed.map { $0[kind] }.filter { $0 != .unavailable }
            let fails = results.filter(\.isFail).count
            if fails >= config.minLossSamples,
               Double(fails) / Double(results.count) > config.lossThreshold {
                reasons.append(.loss(kind))
                continue
            }
            if let p95 = baselineP95(s.interface, kind) {
                let lat = latencyRecent.compactMap { $0[kind].latency }
                if lat.count >= 3 {
                    let med = Self.percentile(lat, 0.5)
                    if med > config.latencyMultiple * p95 && med - p95 > config.latencyFloorMs {
                        reasons.append(.highLatency(kind))
                    }
                }
            }
        }
        return reasons
    }

    private mutating func addToBaseline(_ s: Sample) {
        for kind in ProbeKind.allCases {
            guard let ms = s[kind].latency else { continue }
            var xs = baselines[s.interface, default: [:]][kind, default: []]
            xs.append(ms)
            if xs.count > config.baselineCapacity { xs.removeFirst(xs.count - config.baselineCapacity) }
            baselines[s.interface, default: [:]][kind] = xs
        }
    }

    /// Same indexing as `pct()` in netwatch.py.
    static func percentile(_ xs: [Double], _ p: Double) -> Double {
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}
