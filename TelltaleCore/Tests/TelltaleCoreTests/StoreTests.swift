import Foundation
import Testing
@testable import TelltaleCore

/// Aligned to a minute boundary so aggregate buckets are predictable.
private let m0 = Date(timeIntervalSince1970: 1_700_000_040)

private func sample(_ offset: TimeInterval, iface: InterfaceKind = .wifi,
                    gw: ProbeResult = .ok(5), cf: ProbeResult = .ok(20), go: ProbeResult = .ok(22),
                    dns: ProbeResult = .ok(25), https: ProbeResult = .ok(400),
                    breakdown: HTTPSBreakdown? = nil, wifi: WifiStats? = nil) -> Sample {
    Sample(ts: m0.addingTimeInterval(offset), interface: iface, gateway: gw, cloudflare: cf,
           google: go, dns: dns, https: https, httpsBreakdown: breakdown, wifi: wifi)
}

// MARK: - Samples

@Test func sampleRoundTripKeepsAllThreeStates() throws {
    let store = try Store()
    let s = sample(0, gw: .unavailable, cf: .ok(12.5), go: .fail, dns: .ok(0), https: .ok(431.25),
                   breakdown: HTTPSBreakdown(dnsMs: 59, tcpMs: 89, tlsMs: 331, ttfbMs: 89.3),
                   wifi: WifiStats(rssi: -42, noise: -96, channel: 44, txRateMbps: 1200))
    try store.insert(s)
    let back = try store.samples(from: m0.addingTimeInterval(-1), to: m0.addingTimeInterval(1))
    #expect(back == [s])
}

@Test func sampleWithoutOptionalPartsRoundTrips() throws {
    let store = try Store()
    let s = sample(0, iface: .ethernet)
    try store.insert(s)
    #expect(try store.recentSamples(limit: 1) == [s])
}

@Test func rangeIsHalfOpenAndOrdered() throws {
    let store = try Store()
    for i in [10.0, 0, 5, 15] { try store.insert(sample(i)) }
    let got = try store.samples(from: m0, to: m0.addingTimeInterval(15))
    #expect(got.map(\.ts) == [0, 5, 10].map { m0.addingTimeInterval($0) })
}

@Test func recentSamplesReturnsNewestOldestFirst() throws {
    let store = try Store()
    for i in 0..<10 { try store.insert(sample(Double(i) * 5)) }
    let got = try store.recentSamples(limit: 3)
    #expect(got.map(\.ts) == [35, 40, 45].map { m0.addingTimeInterval($0) })
}

@Test func insertingSameTimestampReplaces() throws {
    let store = try Store()
    try store.insert(sample(0, cf: .ok(10)))
    try store.insert(sample(0, cf: .ok(99)))
    let got = try store.recentSamples(limit: 5)
    #expect(got.count == 1)
    #expect(got[0].cloudflare == .ok(99))
}

// MARK: - Aggregates

@Test func rollUpComputesStatsForCompleteMinutesOnly() throws {
    let store = try Store()
    for i in 0..<12 {   // minute 0: 12 samples, cloudflare 10...21 with one fail at i=11
        try store.insert(sample(Double(i) * 5, gw: .unavailable,
                                cf: i == 11 ? .fail : .ok(Double(10 + i))))
    }
    try store.insert(sample(60))   // minute 1, still in progress

    try store.rollUp(before: m0.addingTimeInterval(90))
    let rows = try store.aggregates(from: m0, to: m0.addingTimeInterval(600))

    #expect(rows.allSatisfy { $0.minute == m0 })              // minute 1 not aggregated yet
    #expect(!rows.contains { $0.probe == .gateway })          // all unavailable -> no row
    let cf = try #require(rows.first { $0.probe == .cloudflare })
    #expect(cf.n == 12)
    #expect(cf.ok == 11)
    #expect(cf.fail == 1)
    #expect(cf.p50 == 15)
    #expect(cf.p95 == 20)
    #expect(cf.max == 20)
}

@Test func rollUpIsIdempotentAndResumes() throws {
    let store = try Store()
    for i in 0..<12 { try store.insert(sample(Double(i) * 5)) }
    for i in 0..<12 { try store.insert(sample(60 + Double(i) * 5)) }

    try store.rollUp(before: m0.addingTimeInterval(60))
    let first = try store.aggregates(from: m0, to: m0.addingTimeInterval(600))
    try store.rollUp(before: m0.addingTimeInterval(60))
    #expect(try store.aggregates(from: m0, to: m0.addingTimeInterval(600)) == first)

    try store.rollUp(before: m0.addingTimeInterval(120))
    let all = try store.aggregates(from: m0, to: m0.addingTimeInterval(600))
    #expect(Set(all.map(\.minute)) == [m0, m0.addingTimeInterval(60)])
    #expect(all.filter { $0.minute == m0 } == first)           // earlier minute unchanged
}

@Test func aggregatesAreSplitPerInterface() throws {
    let store = try Store()
    try store.insert(sample(0, iface: .wifi))
    try store.insert(sample(5, iface: .ethernet))
    try store.rollUp(before: m0.addingTimeInterval(60))
    let rows = try store.aggregates(from: m0, to: m0.addingTimeInterval(60))
    #expect(Set(rows.map(\.interface)) == [.wifi, .ethernet])
}

// MARK: - Retention

@Test func pruneDropsOldRawSamplesButKeepsAggregates() throws {
    let store = try Store()
    let now = m0.addingTimeInterval(50 * 3600)
    try store.insert(sample(0))                                 // 50h old
    try store.insert(sample(50 * 3600))                         // current
    try store.maintain(now: now)

    let raw = try store.samples(from: m0.addingTimeInterval(-1), to: now.addingTimeInterval(1))
    #expect(raw.map(\.ts) == [now])
    let agg = try store.aggregates(from: m0, to: m0.addingTimeInterval(60))
    #expect(!agg.isEmpty)
}

@Test func pruneNeverDeletesUnaggregatedSamples() throws {
    let store = try Store()
    try store.insert(sample(0))
    try store.prune(now: m0.addingTimeInterval(200 * 3600))     // way past retention, no rollUp done
    #expect(try store.recentSamples(limit: 5).count == 1)
}

@Test func pruneDropsAggregatesAndClosedEventsPastNinetyDays() throws {
    let store = try Store()
    try store.insert(sample(0))
    try store.rollUp(before: m0.addingTimeInterval(60))
    try store.apply(Diagnosis(status: .outage(.isp), since: m0, gatewayIcmpBlocked: false), at: m0)
    try store.apply(Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false),
                    at: m0.addingTimeInterval(30))

    try store.prune(now: m0.addingTimeInterval(91 * 24 * 3600))
    #expect(try store.aggregates(from: m0, to: m0.addingTimeInterval(60)).isEmpty)
    #expect(try store.events(from: m0.addingTimeInterval(-10), to: m0.addingTimeInterval(100)).isEmpty)
}

// MARK: - Events

private let healthyDiag = Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false)

@Test func replayedOutageBecomesOneClosedEvent() throws {
    let store = try Store()
    var d = Diagnoser()
    func s(_ i: Int, ok: Bool) -> Sample {
        sample(Double(i) * 5, cf: ok ? .ok(20) : .fail, go: ok ? .ok(22) : .fail,
               dns: ok ? .ok(25) : .fail, https: ok ? .ok(400) : .fail)
    }
    let script = (0..<5).map { s($0, ok: true) } + (5..<8).map { s($0, ok: false) }
               + (8..<12).map { s($0, ok: true) }
    for x in script { try store.apply(d.ingest(x), at: x.ts) }

    let events = try store.events(from: m0.addingTimeInterval(-1), to: m0.addingTimeInterval(1000))
    // The brief "degraded" lead-in (2 lost samples) is absorbed by the outage, and there is no tail.
    #expect(events.count == 1)
    let e = try #require(events.first)
    #expect(e.kind == .outage)
    #expect(e.cause == .isp)
    #expect(e.start == script[5].ts)            // first failing sample, not the sample that tripped hysteresis
    #expect(e.end == script[11].ts)             // sample at which hysteresis cleared
}

@Test func openEventIsVisibleWithNoEnd() throws {
    let store = try Store()
    try store.apply(Diagnosis(status: .outage(.dns), since: m0, gatewayIcmpBlocked: false), at: m0)
    let events = try store.events(from: m0.addingTimeInterval(500), to: m0.addingTimeInterval(1000))
    #expect(events.count == 1)
    #expect(events[0].end == nil)
}

@Test func repeatedIdenticalDiagnosisDoesNotDuplicate() throws {
    let store = try Store()
    let d = Diagnosis(status: .outage(.dns), since: m0, gatewayIcmpBlocked: false)
    for i in 0..<5 { try store.apply(d, at: m0.addingTimeInterval(Double(i) * 5)) }
    #expect(try store.events(from: m0, to: m0.addingTimeInterval(100)).count == 1)
}

@Test func causeShiftUpdatesTheSameEvent() throws {
    let store = try Store()
    try store.apply(Diagnosis(status: .outage(.dns), since: m0, gatewayIcmpBlocked: false), at: m0)
    try store.apply(Diagnosis(status: .outage(.isp), since: m0, gatewayIcmpBlocked: false),
                    at: m0.addingTimeInterval(10))
    let events = try store.events(from: m0, to: m0.addingTimeInterval(100))
    #expect(events.count == 1)
    #expect(events[0].cause == .isp)
}

@Test func degradedThenOutageThenHealthyMakesTwoEvents() throws {
    let store = try Store()
    let t1 = m0, t2 = m0.addingTimeInterval(20), t3 = m0.addingTimeInterval(30), t4 = m0.addingTimeInterval(60)
    try store.apply(Diagnosis(status: .degraded([.loss(.https)]), since: t1, gatewayIcmpBlocked: false), at: t1)
    try store.apply(Diagnosis(status: .outage(.dns), since: t2, gatewayIcmpBlocked: false), at: t3)
    try store.apply(healthyDiag, at: t4)

    let events = try store.events(from: m0, to: m0.addingTimeInterval(100))
    #expect(events.map(\.kind) == [.degraded, .outage])
    #expect(events[0].start == t1 && events[0].end == t2)       // degraded closes where the outage began
    #expect(events[1].start == t2 && events[1].end == t4)
}

@Test func degradedEventRecordsWhichLayerAndFollowsIt() throws {
    let store = try Store()
    func degraded(_ r: [DegradeReason]) -> Diagnosis {
        Diagnosis(status: .degraded(r), since: m0, gatewayIcmpBlocked: false)
    }
    try store.apply(degraded([.loss(.https)]), at: m0)
    #expect(try store.events(from: m0, to: m0.addingTimeInterval(100)).first?.detail == "HTTPS loss")

    try store.apply(degraded([.loss(.dns), .loss(.https)]), at: m0.addingTimeInterval(5))
    let events = try store.events(from: m0, to: m0.addingTimeInterval(100))
    #expect(events.count == 1)                                  // same event, relabelled
    #expect(events[0].detail == "DNS loss")                     // layer closest to the user wins
}

@Test func healthyWithNoOpenEventDoesNothing() throws {
    let store = try Store()
    try store.apply(healthyDiag, at: m0)
    #expect(try store.events(from: m0.addingTimeInterval(-10), to: m0.addingTimeInterval(10)).isEmpty)
}

@Test func pathChangeIsRecordedAsInstantEvent() throws {
    let store = try Store()
    try store.recordPathChange(from: .wifi, to: .ethernet, at: m0)
    let e = try #require(try store.events(from: m0.addingTimeInterval(-1), to: m0.addingTimeInterval(1)).first)
    #expect(e.kind == .pathChange)
    #expect(e.start == m0 && e.end == m0)
    #expect(e.detail == "wifi -> ethernet")
}

// MARK: - Persistence

@Test func fileStoreSurvivesReopen() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appendingPathComponent("telltale.sqlite").path

    let s = sample(0, wifi: WifiStats(rssi: -50, noise: -95, channel: 36, txRateMbps: 866))
    do {
        let store = try Store(path: path)
        try store.insert(s)
        try store.apply(Diagnosis(status: .outage(.isp), since: m0, gatewayIcmpBlocked: false), at: m0)
    }
    let reopened = try Store(path: path)
    #expect(try reopened.recentSamples(limit: 5) == [s])
    #expect(try reopened.events(from: m0, to: m0.addingTimeInterval(10)).first?.cause == .isp)
}
