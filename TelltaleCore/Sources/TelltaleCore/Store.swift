import Foundation
import GRDB

public struct AggregateRow: Equatable, Sendable {
    public var minute: Date
    public var interface: InterfaceKind
    public var probe: ProbeKind
    /// Samples where the probe was evaluated (ok + fail; unavailable excluded).
    public var n: Int
    public var ok: Int
    public var fail: Int
    public var p50: Double?
    public var p95: Double?
    public var max: Double?
}

public enum EventKind: String, Codable, Sendable {
    case outage, degraded
    case pathChange = "path_change"
}

public struct Event: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var kind: EventKind
    public var start: Date
    /// nil while the event is still open.
    public var end: Date?
    public var cause: Cause?
    public var detail: String?
}

public struct Retention: Sendable {
    public var rawSamples: TimeInterval = 48 * 3600
    public var aggregates: TimeInterval = 90 * 24 * 3600
    public init() {}
}

/// SQLite persistence: raw samples, 1-minute aggregates and events.
///
/// Probe columns encode `ProbeResult` as one REAL: latency in ms when ok, -1 for fail, NULL for unavailable.
public final class Store: Sendable {
    private let db: any DatabaseWriter

    /// File-backed store (WAL, so the UI can read while the sampler writes).
    public init(path: String) throws {
        let pool = try DatabasePool(path: path)
        try Self.migrator.migrate(pool)
        db = pool
    }

    /// In-memory store, for tests and previews.
    public init() throws {
        let queue = try DatabaseQueue()
        try Self.migrator.migrate(queue)
        db = queue
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE samples (
                    ts REAL PRIMARY KEY,
                    interface TEXT NOT NULL,
                    gateway REAL, cloudflare REAL, google REAL, dns REAL, https REAL,
                    https_dns REAL, https_tcp REAL, https_tls REAL, https_ttfb REAL,
                    wifi_rssi INTEGER, wifi_noise INTEGER, wifi_channel INTEGER, wifi_tx REAL
                );
                CREATE TABLE agg_1m (
                    minute REAL NOT NULL,
                    interface TEXT NOT NULL,
                    probe TEXT NOT NULL,
                    n INTEGER NOT NULL, ok INTEGER NOT NULL, fail INTEGER NOT NULL,
                    p50 REAL, p95 REAL, max REAL,
                    PRIMARY KEY (minute, interface, probe)
                );
                CREATE TABLE events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    start REAL NOT NULL,
                    end REAL,
                    cause TEXT,
                    detail TEXT
                );
                CREATE INDEX events_start ON events(start);
                """)
        }
        return m
    }

    // MARK: - Samples

    public func insert(_ s: Sample) throws {
        try db.write { db in
            let args: [(any DatabaseValueConvertible)?] = [
                s.ts.timeIntervalSince1970, s.interface.rawValue,
                Self.encode(s.gateway), Self.encode(s.cloudflare), Self.encode(s.google),
                Self.encode(s.dns), Self.encode(s.https),
                s.httpsBreakdown?.dnsMs, s.httpsBreakdown?.tcpMs,
                s.httpsBreakdown?.tlsMs, s.httpsBreakdown?.ttfbMs,
                s.wifi?.rssi, s.wifi?.noise, s.wifi?.channel, s.wifi?.txRateMbps,
            ]
            try db.execute(sql: """
                INSERT OR REPLACE INTO samples
                (ts, interface, gateway, cloudflare, google, dns, https,
                 https_dns, https_tcp, https_tls, https_ttfb,
                 wifi_rssi, wifi_noise, wifi_channel, wifi_tx)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: StatementArguments(args))
        }
    }

    /// Samples with `from <= ts < to`, oldest first.
    public func samples(from: Date, to: Date) throws -> [Sample] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM samples WHERE ts >= ? AND ts < ? ORDER BY ts",
                             arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
                .map(Self.sample(from:))
        }
    }

    /// The newest `limit` samples, oldest first.
    public func recentSamples(limit: Int) throws -> [Sample] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM (SELECT * FROM samples ORDER BY ts DESC LIMIT ?) ORDER BY ts",
                             arguments: [limit])
                .map(Self.sample(from:))
        }
    }

    // MARK: - Aggregates and retention

    /// Aggregates raw samples into 1-minute rows for every complete minute before `cutoff`.
    /// Idempotent: resumes from the last aggregated minute and replaces rows.
    public func rollUp(before cutoff: Date) throws {
        let cutoffMinute = Self.floorMinute(cutoff.timeIntervalSince1970)
        try db.write { db in
            let lastAgg = try Double.fetchOne(db, sql: "SELECT MAX(minute) FROM agg_1m")
            let firstRaw = try Double.fetchOne(db, sql: "SELECT MIN(ts) FROM samples").map(Self.floorMinute)
            guard let start = lastAgg ?? firstRaw, start < cutoffMinute else { return }

            let samples = try Row.fetchAll(
                db, sql: "SELECT * FROM samples WHERE ts >= ? AND ts < ? ORDER BY ts",
                arguments: [start, cutoffMinute]).map(Self.sample(from:))

            struct Key: Hashable { var minute: Double; var interface: InterfaceKind }
            let groups = Dictionary(grouping: samples) {
                Key(minute: Self.floorMinute($0.ts.timeIntervalSince1970), interface: $0.interface)
            }
            for (key, group) in groups {
                for kind in ProbeKind.allCases {
                    let results = group.map { $0[kind] }.filter { $0 != .unavailable }
                    guard !results.isEmpty else { continue }
                    let lat = results.compactMap(\.latency)
                    let args: [(any DatabaseValueConvertible)?] = [
                        key.minute, key.interface.rawValue, kind.rawValue,
                        results.count, lat.count, results.count - lat.count,
                        lat.isEmpty ? nil : Diagnoser.percentile(lat, 0.5),
                        lat.isEmpty ? nil : Diagnoser.percentile(lat, 0.95),
                        lat.max(),
                    ]
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO agg_1m (minute, interface, probe, n, ok, fail, p50, p95, max)
                        VALUES (?,?,?,?,?,?,?,?,?)
                        """, arguments: StatementArguments(args))
                }
            }
        }
    }

    public func aggregates(from: Date, to: Date) throws -> [AggregateRow] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agg_1m WHERE minute >= ? AND minute < ? ORDER BY minute, probe",
                             arguments: [from.timeIntervalSince1970, to.timeIntervalSince1970])
                .compactMap { r in
                    guard let iface = InterfaceKind(rawValue: r["interface"]),
                          let probe = ProbeKind(rawValue: r["probe"]) else { return nil }
                    return AggregateRow(minute: Date(timeIntervalSince1970: r["minute"]),
                                        interface: iface, probe: probe,
                                        n: r["n"], ok: r["ok"], fail: r["fail"],
                                        p50: r["p50"], p95: r["p95"], max: r["max"])
                }
        }
    }

    /// Deletes data past retention. Raw samples are never deleted before they have been aggregated.
    public func prune(now: Date, retention: Retention = Retention()) throws {
        let t = now.timeIntervalSince1970
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM samples
                WHERE ts < ? AND ts < (SELECT COALESCE(MAX(minute) + 60, 0) FROM agg_1m)
                """, arguments: [t - retention.rawSamples])
            try db.execute(sql: "DELETE FROM agg_1m WHERE minute < ?", arguments: [t - retention.aggregates])
            try db.execute(sql: "DELETE FROM events WHERE end IS NOT NULL AND end < ?",
                           arguments: [t - retention.aggregates])
        }
    }

    /// Periodic housekeeping: aggregate complete minutes, then prune.
    public func maintain(now: Date, retention: Retention = Retention()) throws {
        try rollUp(before: now)
        try prune(now: now, retention: retention)
    }

    // MARK: - Events

    /// Opens, updates or closes the outage/degraded event so it mirrors `diagnosis`.
    /// Call once per diagnosis; `ts` is the time of the sample that produced it.
    public func apply(_ diagnosis: Diagnosis, at ts: Date) throws {
        try db.write { db in
            let want: (kind: EventKind, cause: Cause?, detail: String?)? = switch diagnosis.status {
            case .healthy: nil
            case .degraded(let reasons): (.degraded, nil, MenuBarState.degradedLabel(reasons))
            case .outage(let c): (.outage, c, nil)
            }
            let open = try Row.fetchOne(db, sql: """
                SELECT * FROM events WHERE end IS NULL AND kind IN ('outage','degraded')
                ORDER BY id DESC LIMIT 1
                """).map(Self.event(from:))

            if let open, let want, open.kind == want.kind {
                if want.kind == .outage, open.cause != want.cause {
                    try db.execute(sql: "UPDATE events SET cause = ? WHERE id = ?",
                                   arguments: [want.cause?.rawValue, open.id])
                }
                if want.kind == .degraded, open.detail != want.detail {
                    try db.execute(sql: "UPDATE events SET detail = ? WHERE id = ?",
                                   arguments: [want.detail, open.id])
                }
                return
            }
            let newStart = diagnosis.since ?? ts
            if let open {
                if open.kind == .degraded, want?.kind == .outage, newStart <= open.start {
                    // The outage began no later than the degraded run: it absorbs it.
                    try db.execute(sql: "DELETE FROM events WHERE id = ?", arguments: [open.id])
                } else {
                    let end = Swift.max(open.start, want?.kind == .outage ? newStart : ts)
                    try db.execute(sql: "UPDATE events SET end = ? WHERE id = ?",
                                   arguments: [end.timeIntervalSince1970, open.id])
                }
            }
            if let want {
                try db.execute(sql: "INSERT INTO events (kind, start, cause, detail) VALUES (?,?,?,?)",
                               arguments: [want.kind.rawValue, newStart.timeIntervalSince1970,
                                           want.cause?.rawValue, want.detail])
            }
        }
    }

    public func recordPathChange(from: InterfaceKind, to: InterfaceKind, at ts: Date) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO events (kind, start, end, detail) VALUES (?,?,?,?)",
                           arguments: [EventKind.pathChange.rawValue, ts.timeIntervalSince1970,
                                       ts.timeIntervalSince1970, "\(from.rawValue) -> \(to.rawValue)"])
        }
    }

    /// Events overlapping `[from, to)`, oldest first. Open events overlap everything after their start.
    public func events(from: Date, to: Date) throws -> [Event] {
        try db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM events WHERE start < ? AND (end IS NULL OR end >= ?) ORDER BY start, id
                """, arguments: [to.timeIntervalSince1970, from.timeIntervalSince1970])
                .map(Self.event(from:))
        }
    }

    // MARK: - Row mapping

    private static func floorMinute(_ t: Double) -> Double { (t / 60).rounded(.down) * 60 }

    private static func encode(_ r: ProbeResult) -> Double? {
        switch r {
        case .ok(let ms): return ms
        case .fail: return -1
        case .unavailable: return nil
        }
    }

    private static func decode(_ v: Double?) -> ProbeResult {
        guard let v else { return .unavailable }
        return v < 0 ? .fail : .ok(v)
    }

    private static func sample(from r: Row) -> Sample {
        let breakdown: HTTPSBreakdown? = {
            let b = HTTPSBreakdown(dnsMs: r["https_dns"], tcpMs: r["https_tcp"],
                                   tlsMs: r["https_tls"], ttfbMs: r["https_ttfb"])
            return b == HTTPSBreakdown() ? nil : b
        }()
        let wifi: WifiStats? = {
            guard let rssi: Int = r["wifi_rssi"] else { return nil }
            return WifiStats(rssi: rssi, noise: r["wifi_noise"] ?? 0,
                             channel: r["wifi_channel"] ?? 0, txRateMbps: r["wifi_tx"] ?? 0)
        }()
        return Sample(
            ts: Date(timeIntervalSince1970: r["ts"]),
            interface: InterfaceKind(rawValue: r["interface"]) ?? .other,
            gateway: decode(r["gateway"]), cloudflare: decode(r["cloudflare"]),
            google: decode(r["google"]), dns: decode(r["dns"]), https: decode(r["https"]),
            httpsBreakdown: breakdown, wifi: wifi)
    }

    private static func event(from r: Row) -> Event {
        let end: Double? = r["end"]
        let cause: String? = r["cause"]
        return Event(id: r["id"], kind: EventKind(rawValue: r["kind"]) ?? .outage,
                     start: Date(timeIntervalSince1970: r["start"]),
                     end: end.map(Date.init(timeIntervalSince1970:)),
                     cause: cause.flatMap(Cause.init(rawValue:)),
                     detail: r["detail"])
    }
}
