import Foundation
import Testing
@testable import TelltaleCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_040)      // minute-aligned: 2023-11-14T22:14:00Z

private func sample(_ off: TimeInterval, https: ProbeResult = .ok(280), cf: ProbeResult = .ok(6)) -> Sample {
    Sample(ts: t0.addingTimeInterval(off), gateway: .ok(5), cloudflare: cf, google: .ok(6), dns: .ok(40), https: https)
}

private func every(_ step: TimeInterval, from a: TimeInterval, to b: TimeInterval,
                   https: @escaping (Int) -> ProbeResult = { _ in .ok(280) }) -> [Sample] {
    stride(from: a, to: b, by: step).enumerated().map { sample($1, https: https($0)) }
}

private func span(_ seconds: TimeInterval) -> DateInterval { DateInterval(start: t0, duration: seconds) }

private func event(_ start: TimeInterval, _ duration: TimeInterval?, kind: EventKind = .outage) -> Event {
    Event(id: Int64(start), kind: kind, start: t0.addingTimeInterval(start),
          end: duration.map { t0.addingTimeInterval(start + $0) }, cause: .isp, detail: nil)
}

private func build(_ samples: [Sample], events: [Event] = [], range: DateInterval, now: Date? = nil,
                   buckets: Int = 60) -> HistoryView {
    History.build(.raw(samples), events: events, range: range, now: now ?? range.end, buckets: buckets)
}

// MARK: - Bucketing

@Test func rawSamplesLandInTheirOwnBuckets() {
    let samples = every(10, from: 0, to: 600) { $0 == 5 ? .fail : .ok(100 + Double($0)) }
    let v = build(samples, range: span(600))
    let https = v.series[.https]!
    #expect(v.source == .raw)
    #expect(v.bucketWidth == 10)
    #expect(https.count == 60)
    #expect(https[0].value == 100)
    #expect(https[0].ts == t0.addingTimeInterval(5))               // bucket centre
    #expect(https[5].value == nil && https[5].failures == 1)       // everything failed: the line breaks here
    #expect(https[6].value == 106)
    #expect(v.gaps.isEmpty)
}

@Test func aBucketKeepsItsPeakAndCountsFailures() {
    let samples = [sample(0, https: .ok(10)), sample(2, https: .ok(50)), sample(4, https: .ok(20)),
                   sample(5, https: .fail)]
    let p = build(samples, range: span(60), buckets: 6).series[.https]![0]
    #expect(p.value == 50)
    #expect(p.failures == 1)
    #expect(p.samples == 4)
}

@Test func samplesOutsideTheRangeAreIgnored() {
    let v = build([sample(-20), sample(5), sample(700)], range: span(60), buckets: 6)
    #expect(v.series[.https]!.count == 1)
}

@Test func unavailableProbesAreNotCounted() {
    var s = sample(0)
    s.gateway = .unavailable
    let v = build([s], range: span(60), buckets: 6)
    #expect(v.series[.gateway]!.isEmpty)
    #expect(v.series[.https]!.count == 1)
}

// MARK: - Gaps

@Test func timeWithoutSamplesIsAGapAndBucketsAreOmitted() {
    let samples = every(10, from: 0, to: 110) + every(10, from: 400, to: 600).map { sample($0.ts.timeIntervalSince(t0)) }
    let v = build(samples, range: span(600))
    #expect(v.gaps == [DateInterval(start: t0.addingTimeInterval(100), end: t0.addingTimeInterval(400))])
    #expect(v.series[.https]!.count == 31)                          // 11 before the gap, 20 after
    #expect(v.summary.monitoredFraction == 0.5)
}

@Test func timeBeforeTheFirstAndAfterTheLastSampleIsAGap() {
    let v = build(every(10, from: 100, to: 510), range: span(600))
    #expect(v.gaps == [DateInterval(start: t0, end: t0.addingTimeInterval(100)),
                       DateInterval(start: t0.addingTimeInterval(500), end: t0.addingTimeInterval(600))])
}

@Test func noDataAtAllIsOneGapAndNoUptime() {
    let v = build([], range: span(600))
    #expect(v.gaps == [span(600)])
    #expect(v.series[.https]!.isEmpty)
    #expect(v.summary.uptime == nil)
    #expect(v.summary.monitoredFraction == 0)
}

// MARK: - Summary

@Test func outageReducesUptimeAndDegradedDoesNot() {
    let samples = every(10, from: 0, to: 600)
    let v = build(samples, events: [event(100, 60), event(300, 200, kind: .degraded)], range: span(600))
    #expect(v.summary.outageCount == 1)
    #expect(v.summary.downtime == 60)
    #expect(v.summary.longestOutage == 60)
    #expect(abs((v.summary.uptime ?? 0) - 0.9) < 1e-9)
    #expect(v.events.count == 2)
}

@Test func anOpenOutageRunsToNowButNeverPastTheRange() {
    let samples = every(10, from: 0, to: 600)
    let v = build(samples, events: [event(500, nil)], range: span(600), now: t0.addingTimeInterval(700))
    #expect(v.summary.downtime == 100)                              // 500...600, clipped to the range
}

@Test func anOutageStartingBeforeTheRangeIsClipped() {
    let samples = every(10, from: 0, to: 600)
    let v = build(samples, events: [event(-30, 60)], range: span(600))
    #expect(v.summary.downtime == 30)
    #expect(v.summary.outageCount == 1)
}

@Test func uptimeIsMeasuredOverMonitoredTimeOnly() {
    // data for the first 290 s only; a 30 s outage inside it
    let v = build(every(10, from: 0, to: 300), events: [event(100, 30)], range: span(600))
    #expect(abs(v.summary.monitoredFraction - 290.0 / 600) < 1e-9)
    #expect(abs((v.summary.uptime ?? 0) - (1 - 30.0 / 290)) < 1e-9)
}

// MARK: - Aggregates

private func agg(_ minute: Int, _ probe: ProbeKind = .cloudflare, iface: InterfaceKind = .wifi,
                 ok: Int = 12, fail: Int = 0, max: Double? = 8) -> AggregateRow {
    AggregateRow(minute: t0.addingTimeInterval(Double(minute) * 60), interface: iface, probe: probe,
                 n: ok + fail, ok: ok, fail: fail, p50: 6, p95: 7, max: max)
}

@Test func aggregatesCombineInterfacesAndFindMissingMinutes() {
    var rows = [agg(0), agg(0, iface: .ethernet, ok: 6, fail: 6, max: 20)]
    rows += (2..<10).map { agg($0) }                                // minute 1 is missing
    let v = History.build(.aggregates(rows), events: [], range: span(600), now: t0.addingTimeInterval(86_400 * 100),
                          buckets: 10)
    let first = v.series[.cloudflare]![0]
    #expect(v.source == .aggregates)
    #expect(first.value == 20)                                      // peak across interfaces
    #expect(first.failures == 6)
    #expect(first.samples == 24)
    #expect(v.gaps == [DateInterval(start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(120))])
}

@Test func aMissingTailNearNowIsNotAGapForAggregates() {
    let rows = (0..<6).map { agg($0) }
    let near = History.build(.aggregates(rows), events: [], range: span(600), now: t0.addingTimeInterval(600), buckets: 10)
    #expect(near.gaps.isEmpty)                                      // aggregates lag the present
    let far = History.build(.aggregates(rows), events: [], range: span(600),
                            now: t0.addingTimeInterval(86_400 * 100), buckets: 10)
    #expect(far.gaps == [DateInterval(start: t0.addingTimeInterval(360), end: t0.addingTimeInterval(600))])
}

// MARK: - Slow cadence

@Test func aThirtySecondCadenceIsNotMistakenForGaps() {
    let v = build(every(30, from: 0, to: 3600), range: span(3600), buckets: 120)
    #expect(v.gaps.isEmpty)
    #expect(v.runs(for: .https).count == 1)                        // consecutive samples are joined into one line
    #expect(v.summary.monitoredFraction == 1)
    #expect(v.summary.uptime == 1)
}

@Test func aSleepIsStillAGapAtTheSlowCadence() {
    let samples = every(30, from: 0, to: 600) + every(30, from: 1800, to: 2400).map { sample($0.ts.timeIntervalSince(t0)) }
    let v = build(samples, range: span(2400), buckets: 120)
    #expect(v.gaps.count == 1)
    #expect(v.runs(for: .https).count == 2)                        // the line breaks across it
}

// MARK: - Chart runs and durations

@Test func runsBreakWhereEveryProbeFailedAndWhereDataIsMissing() {
    // 31 buckets of 10 s: ok 0-4, all failed at 5, ok 6-8, no data 9-19, ok 20-30
    let samples = (0..<31).filter { !(9..<20).contains($0) }.map { i in
        sample(Double(i) * 10, https: i == 5 ? .fail : .ok(100))
    }
    let v = build(samples, range: span(310), buckets: 31)
    let runs = v.runs(for: .https)
    #expect(runs.map(\.count) == [5, 3, 11])
    #expect(v.runs(for: .gateway).map(\.count) == [9, 11])         // no failure there, but the data gap still breaks it
}

@Test func shortDurations() {
    #expect(History.shortDuration(0) == "0 s")
    #expect(History.shortDuration(45) == "45 s")
    #expect(History.shortDuration(185) == "3 min")
    #expect(History.shortDuration(3600) == "1 h")
    #expect(History.shortDuration(3900) == "1 h 5 min")
    #expect(History.shortDuration(2 * 86_400) == "2 d")
    #expect(History.shortDuration(2 * 86_400 + 3 * 3600) == "2 d 3 h")
    #expect(History.shortDuration(-5) == "0 s")
}

// MARK: - Grouping by day

@Test func eventsGroupByCalendarDayNewestFirst() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    // t0 is 22:14 UTC on Nov 14; +3 h is 01:14 UTC on Nov 15
    let events = [event(0, 120), event(60, 30, kind: .degraded), event(3 * 3600, nil)]
    let groups = History.groupByDay(events, now: t0.addingTimeInterval(3 * 3600 + 300), calendar: utc)
    #expect(groups.count == 2)
    #expect(groups[0].events.count == 1)                            // Nov 15, newest day first
    #expect(groups[0].downtime == 300)                              // the open outage counts up to now
    #expect(groups[1].events.map(\.kind) == [.degraded, .outage])   // newest first within the day
    #expect(groups[1].outageCount == 1 && groups[1].downtime == 120)
}

// MARK: - From the Store

@Test func viewReadsRawForRecentRangesAndAggregatesForOldOnes() throws {
    let store = try Store()
    let now = t0.addingTimeInterval(5 * 86_400)
    for i in 0..<12 { try store.insert(sample(2 * 86_400 + Double(i) * 5)) }                  // 3 days before now
    for i in 0..<12 { try store.insert(sample(5 * 86_400 - 3600 + Double(i) * 5)) }           // 1 hour before now
    try store.apply(Diagnosis(status: .outage(.isp), since: t0.addingTimeInterval(2 * 86_400), gatewayIcmpBlocked: false),
                    at: t0.addingTimeInterval(2 * 86_400))
    try store.rollUp(before: now)

    let recent = try History.view(store: store, range: DateInterval(start: now.addingTimeInterval(-3600 - 60), end: now),
                                  now: now, buckets: 60)
    #expect(recent.source == .raw)
    #expect(recent.series[.https]!.reduce(0) { $0 + $1.samples } == 12)    // every sample is in some bucket

    let old = try History.view(store: store, range: DateInterval(start: now.addingTimeInterval(-4 * 86_400), end: now),
                               now: now, buckets: 100)
    #expect(old.source == .aggregates)
    #expect(!old.series[.https]!.isEmpty)
    #expect(old.events.contains { $0.kind == .outage })
}
