import Foundation

/// CSV for the History window's export.
///
/// The first six sample columns match `netwatch.csv` (`ts,gateway,cloudflare,google,dns,https`: local time without
/// an offset, milliseconds, blank = failed), so `netwatch.py report` can read the file; it ignores the extra columns.
/// `ts_utc` carries the unambiguous time, since a local time repeats for an hour when daylight saving ends.
/// Fields are quoted per RFC 4180 when needed; rows end in "\n".
public enum CSVExport {
    static let sampleHeader = [
        "ts", "gateway", "cloudflare", "google", "dns", "https",
        "ts_utc", "interface", "unavailable",
        "https_dns_ms", "https_tcp_ms", "https_tls_ms", "https_ttfb_ms",
        "wifi_rssi", "wifi_noise", "wifi_channel", "wifi_tx_mbps",
    ]
    static let eventHeader = ["start", "end", "duration_s", "kind", "cause", "detail", "start_utc", "end_utc"]

    /// One row per sample. A probe that failed or could not run is blank; `unavailable` names the latter.
    public static func samples(_ samples: [Sample], timeZone: TimeZone = .current) -> String {
        let f = Formats(timeZone)
        var lines = [row(sampleHeader)]
        for s in samples {
            let wifi = s.wifi
            lines.append(row([
                f.local(s.ts),
                ms(s.gateway), ms(s.cloudflare), ms(s.google), ms(s.dns), ms(s.https),
                f.utc(s.ts), s.interface.rawValue,
                ProbeKind.allCases.filter { s[$0] == .unavailable }.map(\.rawValue).joined(separator: ";"),
                opt(s.httpsBreakdown?.dnsMs), opt(s.httpsBreakdown?.tcpMs),
                opt(s.httpsBreakdown?.tlsMs), opt(s.httpsBreakdown?.ttfbMs),
                wifi.map { String($0.rssi) } ?? "", wifi.map { String($0.noise) } ?? "",
                wifi.map { String($0.channel) } ?? "", wifi.map { String(format: "%.0f", $0.txRateMbps) } ?? "",
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One row per event. An event that is still open has a blank `end`; its duration runs to `now`.
    public static func events(_ events: [Event], now: Date, timeZone: TimeZone = .current) -> String {
        let f = Formats(timeZone)
        var lines = [row(eventHeader)]
        for e in events {
            let seconds = Int(max(0, (e.end ?? now).timeIntervalSince(e.start)).rounded())
            lines.append(row([
                f.local(e.start), e.end.map(f.local) ?? "", String(seconds),
                e.kind.rawValue, e.cause?.rawValue ?? "", e.detail ?? "",
                f.utc(e.start), e.end.map(f.utc) ?? "",
            ]))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting

    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func row(_ fields: [String]) -> String { fields.map(field).joined(separator: ",") }

    private static func ms(_ r: ProbeResult) -> String {
        r.latency.map { String(format: "%.1f", $0) } ?? ""
    }

    private static func opt(_ v: Double?) -> String {
        v.map { String(format: "%.1f", $0) } ?? ""
    }

    private struct Formats {
        let localFormatter = DateFormatter()
        let utcFormatter = DateFormatter()

        init(_ timeZone: TimeZone) {
            for f in [localFormatter, utcFormatter] {
                f.locale = Locale(identifier: "en_US_POSIX")
                f.calendar = Calendar(identifier: .gregorian)
            }
            localFormatter.timeZone = timeZone
            localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            utcFormatter.timeZone = TimeZone(identifier: "UTC")
            utcFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        }

        func local(_ d: Date) -> String { localFormatter.string(from: d) }
        func utc(_ d: Date) -> String { utcFormatter.string(from: d) }
    }
}
