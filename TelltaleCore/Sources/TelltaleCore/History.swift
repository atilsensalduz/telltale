import Foundation

/// One chart bucket for one layer.
public struct HistoryPoint: Equatable, Sendable {
    /// Centre of the bucket.
    public var ts: Date
    /// Highest latency in the bucket (ms); nil when every probe in it failed.
    public var value: Double?
    public var failures: Int
    /// Probes evaluated in the bucket (ok + failed).
    public var samples: Int
}

public struct HistorySummary: Equatable, Sendable {
    /// 0...1 over the monitored part of the range; nil when nothing was monitored.
    public var uptime: Double?
    public var outageCount: Int
    public var downtime: TimeInterval
    public var longestOutage: TimeInterval
    /// 0...1: how much of the range had data. Sleep, pauses and time before the app started are not monitored.
    public var monitoredFraction: Double
}

public struct HistoryView: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case raw, aggregates }

    public var range: DateInterval
    public var source: Source
    public var bucketWidth: TimeInterval
    /// Only buckets that have data are present. A line should break where consecutive points are more than
    /// about 1.5 `bucketWidth` apart.
    public var series: [ProbeKind: [HistoryPoint]]
    /// Events overlapping the range, oldest first.
    public var events: [Event]
    /// Parts of the range with no data.
    public var gaps: [DateInterval]
    public var summary: HistorySummary
}

public enum HistoryInput {
    case raw([Sample])
    case aggregates([AggregateRow])
}

/// Events of one calendar day, for the event table when the range is long.
public struct DayGroup: Equatable, Sendable {
    public var day: Date
    /// Newest first.
    public var events: [Event]
    public var outageCount: Int
    public var downtime: TimeInterval
}

public enum History {
    /// Seconds between raw samples beyond which nobody was watching. Chosen for the 30 s sampling cadence
    /// (2.5 times it); a tighter value would read every healthy sample as a gap.
    public static let rawGapTolerance: TimeInterval = 75

    /// Raw samples exist for 48 hours; older ranges come from the 1-minute aggregates.
    public static func view(store: Store, range: DateInterval, now: Date = Date(),
                            buckets: Int = 600, rawRetention: TimeInterval = 48 * 3600) throws -> HistoryView {
        let events = try store.events(from: range.start, to: range.end)
        let input: HistoryInput
        if range.start >= now.addingTimeInterval(-rawRetention) {
            input = .raw(try store.samples(from: range.start, to: range.end))
        } else {
            input = .aggregates(try store.aggregates(from: range.start, to: range.end))
        }
        return build(input, events: events, range: range, now: now, buckets: buckets)
    }

    /// Pure core of `view`, so it can be tested without a database.
    public static func build(_ input: HistoryInput, events: [Event], range: DateInterval,
                             now: Date, buckets: Int = 600) -> HistoryView {
        let count = max(1, buckets)
        let width = range.duration / Double(count)

        struct Acc { var peak: Double?; var ok = 0; var fail = 0 }
        var acc: [ProbeKind: [Acc]] = Dictionary(uniqueKeysWithValues:
            ProbeKind.allCases.map { ($0, Array(repeating: Acc(), count: count)) })

        func index(_ t: Date) -> Int? {
            guard width > 0, t >= range.start, t <= range.end else { return nil }
            return min(count - 1, Int(t.timeIntervalSince(range.start) / width))
        }

        let stamps: [Date]
        let cover: TimeInterval
        let tolerance: TimeInterval
        let source: HistoryView.Source

        switch input {
        case .raw(let samples):
            source = .raw; cover = 0; tolerance = rawGapTolerance
            var times: [Date] = []
            for s in samples {
                guard let i = index(s.ts) else { continue }
                times.append(s.ts)
                for kind in ProbeKind.allCases {
                    switch s[kind] {
                    case .ok(let ms):
                        acc[kind]![i].ok += 1
                        acc[kind]![i].peak = max(acc[kind]![i].peak ?? ms, ms)
                    case .fail: acc[kind]![i].fail += 1
                    case .unavailable: break
                    }
                }
            }
            stamps = times.sorted()
        case .aggregates(let rows):
            source = .aggregates; cover = 60; tolerance = 30
            var minutes = Set<Date>()
            for r in rows {
                guard let i = index(r.minute.addingTimeInterval(30)) else { continue }
                minutes.insert(r.minute)
                acc[r.probe]![i].ok += r.ok
                acc[r.probe]![i].fail += r.fail
                if let m = r.max { acc[r.probe]![i].peak = max(acc[r.probe]![i].peak ?? m, m) }
            }
            stamps = minutes.sorted()
        }

        var series: [ProbeKind: [HistoryPoint]] = [:]
        for kind in ProbeKind.allCases {
            series[kind] = acc[kind]!.enumerated().compactMap { i, a in
                let n = a.ok + a.fail
                guard n > 0 else { return nil }
                return HistoryPoint(ts: range.start.addingTimeInterval((Double(i) + 0.5) * width),
                                    value: a.ok > 0 ? a.peak : nil, failures: a.fail, samples: n)
            }
        }

        // Anything longer than `tolerance` between covered stretches is time nobody was watching.
        var gaps: [DateInterval] = []
        var cursor = range.start
        for t in stamps {
            if t.timeIntervalSince(cursor) > tolerance { gaps.append(DateInterval(start: cursor, end: t)) }
            cursor = max(cursor, t.addingTimeInterval(cover))
        }
        // Aggregates lag the present by a few minutes, so a missing tail there is not a gap.
        let tailIsLagging = source == .aggregates && range.end >= now.addingTimeInterval(-600)
        if range.end.timeIntervalSince(cursor) > tolerance && !tailIsLagging {
            gaps.append(DateInterval(start: cursor, end: range.end))
        }

        return HistoryView(
            range: range, source: source, bucketWidth: width, series: series,
            events: events.sorted { $0.start < $1.start }, gaps: gaps,
            summary: summarize(events: events, gaps: gaps, range: range, now: now))
    }

    static func summarize(events: [Event], gaps: [DateInterval], range: DateInterval, now: Date) -> HistorySummary {
        let monitored = max(0, range.duration - gaps.reduce(0) { $0 + $1.duration })
        var downtime: TimeInterval = 0, longest: TimeInterval = 0, count = 0
        for e in events where e.kind == .outage {
            let end = min(e.end ?? now, range.end)
            let start = max(e.start, range.start)
            guard end >= start else { continue }
            count += 1
            let d = end.timeIntervalSince(start)
            downtime += d
            longest = max(longest, d)
        }
        return HistorySummary(
            uptime: monitored > 0 ? min(1, max(0, 1 - downtime / monitored)) : nil,
            outageCount: count, downtime: downtime, longestOutage: longest,
            monitoredFraction: range.duration > 0 ? monitored / range.duration : 0)
    }

    /// Groups events by calendar day, newest day first. An open outage counts up to `now`.
    public static func groupByDay(_ events: [Event], now: Date, calendar: Calendar = .current) -> [DayGroup] {
        let byDay = Dictionary(grouping: events) { calendar.startOfDay(for: $0.start) }
        return byDay.keys.sorted(by: >).map { day in
            let dayEvents = byDay[day]!.sorted { $0.start > $1.start }
            let outages = dayEvents.filter { $0.kind == .outage }
            let downtime = outages.reduce(0.0) { $0 + max(0, ($1.end ?? now).timeIntervalSince($1.start)) }
            return DayGroup(day: day, events: dayEvents, outageCount: outages.count, downtime: downtime)
        }
    }

    /// "45 s", "3 min", "1 h 5 min", "2 d 3 h".
    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds).rounded())
        if s < 60 { return "\(s) s" }
        let m = s / 60
        if m < 60 { return "\(m) min" }
        let h = m / 60, rm = m % 60
        if h < 48 { return rm == 0 ? "\(h) h" : "\(h) h \(rm) min" }
        let d = h / 24, rh = h % 24
        return rh == 0 ? "\(d) d" : "\(d) d \(rh) h"
    }
}

extension HistoryView {
    /// Lines for one layer: consecutive buckets joined, broken at gaps in the data and where every probe
    /// in a bucket failed.
    public func runs(for kind: ProbeKind) -> [[HistoryPoint]] {
        var runs: [[HistoryPoint]] = []
        var current: [HistoryPoint] = []
        for p in series[kind] ?? [] {
            guard p.value != nil else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            if let last = current.last, p.ts.timeIntervalSince(last.ts) > max(bucketWidth * 1.5, History.rawGapTolerance) {
                runs.append(current); current = []
            }
            current.append(p)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}
