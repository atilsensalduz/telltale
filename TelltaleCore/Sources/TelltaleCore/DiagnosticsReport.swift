import Foundation

/// The plain-text block behind "Copy diagnostics": enough to paste into a support ticket
/// or a message to an ISP. Built from values only, so it is unit-tested.
public enum DiagnosticsReport {
    /// - Parameters:
    ///   - samples: the recent window (oldest first), normally the last 10 minutes.
    ///   - events: recent events from the Store, normally the last 24 hours.
    public static func make(
        samples: [Sample], diagnosis: Diagnosis?, events: [Event], now: Date,
        time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) },
        stamp: (Date) -> String = { $0.formatted(date: .abbreviated, time: .standard) },
        exactTime: (Date) -> String = { $0.formatted(date: .omitted, time: .standard) }
    ) -> String {
        let banner = PopoverContent.banner(diagnosis: diagnosis, now: now, time: time)
        let rows = PopoverContent.rows(samples: samples, diagnosis: diagnosis)
        var out: [String] = []

        out.append("Telltale diagnostics, \(stamp(now))")
        out.append("Status: \(banner.title)")
        out.append("  \(banner.subtitle)")
        if let note = banner.note { out.append("  \(note)") }
        if let line = PopoverContent.connectionLine(samples.last) { out.append("Connection: \(line)") }

        if let latest = samples.last {
            out.append("")
            out.append("Latest sample (\(time(latest.ts)))")
            for row in rows { out.append("  \(pad(row.kind.displayName)) \(row.valueText)") }
        }

        out.append("")
        out.append("Last 30 minutes (\(samples.count) samples)")
        for kind in ProbeKind.allCases {
            out.append("  \(pad(kind.displayName)) \(stats(samples, kind))")
        }

        out.append("")
        out.append("Events, last 24 h")
        if events.isEmpty {
            out.append("  none")
        } else {
            for e in events { out.append("  \(describe(e, now: now, time: exactTime))") }
        }
        return out.joined(separator: "\n")
    }

    private static func pad(_ s: String) -> String { s.padding(toLength: 8, withPad: " ", startingAt: 0) }

    static func stats(_ samples: [Sample], _ kind: ProbeKind) -> String {
        let results = samples.map { $0[kind] }.filter { $0 != .unavailable }
        guard !results.isEmpty else { return "no data" }
        let latencies = results.compactMap(\.latency)
        let loss = Double(results.count - latencies.count) / Double(results.count) * 100
        var text = String(format: "loss %.1f%%", loss)
        if !latencies.isEmpty {
            let median = PopoverContent.valueText(.ok(Diagnoser.percentile(latencies, 0.5)))
            let p95 = PopoverContent.valueText(.ok(Diagnoser.percentile(latencies, 0.95)))
            text += ", median \(median), p95 \(p95)"
        }
        return text
    }

    static func describe(_ e: Event, now: Date, time: (Date) -> String) -> String {
        let kind: String
        switch e.kind {
        case .outage: kind = "outage"
        case .degraded: kind = "degraded"
        case .pathChange: kind = "path change"
        }
        let what = e.cause?.rawValue ?? e.detail ?? ""
        if e.kind == .pathChange { return "\(time(e.start))  \(kind)  \(what)" }
        let end = e.end
        let span = PopoverContent.durationText((end ?? now).timeIntervalSince(e.start))
        return "\(time(e.start))-\(end.map(time) ?? "ongoing") (\(span))  \(kind)  \(what)"
            .trimmingCharacters(in: .whitespaces)
    }
}
