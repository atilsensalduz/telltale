import Foundation
import Testing
@testable import TelltaleCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func sample(
    _ i: Int, step: TimeInterval = 5, iface: InterfaceKind = .wifi,
    gw: ProbeResult = .ok(5), cf: ProbeResult = .ok(20), go: ProbeResult = .ok(22),
    dns: ProbeResult = .ok(25), https: ProbeResult = .ok(400)
) -> Sample {
    Sample(ts: t0.addingTimeInterval(Double(i) * step), interface: iface,
           gateway: gw, cloudflare: cf, google: go, dns: dns, https: https)
}

/// Healthy sample with a little latency jitter so baselines have a spread.
private func healthy(_ i: Int, iface: InterfaceKind = .wifi) -> Sample {
    let j = Double(i % 5)
    return sample(i, iface: iface, gw: .ok(4 + j * 0.2), cf: .ok(20 + j), go: .ok(22 + j),
                  dns: .ok(25 + j), https: .ok(400 + j * 10))
}

@discardableResult
private func feed(_ d: inout Diagnoser, _ samples: [Sample]) -> [Diagnosis] {
    samples.map { d.ingest($0) }
}

// MARK: - Stateless rules vs Python oracle

private struct RuleRow: Decodable { let ok: String; let cause: String? }

@Test func ruleTableMatchesPythonOracle() throws {
    let url = try #require(Bundle.module.url(forResource: "rule_table", withExtension: "json",
                                              subdirectory: "Fixtures"))
    let rows = try JSONDecoder().decode([RuleRow].self, from: Data(contentsOf: url))
    #expect(rows.count == 32)
    for row in rows {
        let r = row.ok.map { $0 == "1" ? ProbeResult.ok(10) : ProbeResult.fail }
        let s = sample(0, gw: r[0], cf: r[1], go: r[2], dns: r[3], https: r[4])
        let expected: Cause? = switch row.cause {
        case nil: nil
        case let c? where c.hasPrefix("Local"): .localNetwork
        case let c? where c.hasPrefix("ISP"): .isp
        case let c? where c.hasPrefix("DNS"): .dns
        case let c? where c.hasPrefix("Web path"): .webPath
        default: nil
        }
        #expect(row.cause == nil || expected != nil, "unmapped python cause \(row.cause ?? "")")
        #expect(Rules.classify(s) == expected, "pattern \(row.ok)")
    }
}

@Test func unavailableIsNeverAFailure() {
    let s = sample(0, gw: .unavailable, cf: .unavailable, go: .unavailable, dns: .unavailable, https: .unavailable)
    #expect(Rules.classify(s) == nil)
}

// MARK: - Outage hysteresis

@Test func healthyStaysHealthy() {
    var d = Diagnoser()
    for diag in feed(&d, (0..<20).map { healthy($0) }) {
        #expect(diag.status == .healthy)
        #expect(diag.since == nil)
    }
}

@Test func singleFailedSampleIsNotAnOutage() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    let diag = d.ingest(sample(5, https: .fail))
    if case .outage = diag.status { Issue.record("one failure must not be an outage") }
}

@Test func ispOutageEntersAfterThreeAndClearsAfterFourGood() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    let fails = (5..<8).map { sample($0, cf: .fail, go: .fail, dns: .fail, https: .fail) }
    let out = feed(&d, fails)
    #expect(out[0].status != .outage(.isp))
    #expect(out[1].status != .outage(.isp))
    #expect(out[2].status == .outage(.isp))
    #expect(out[2].since == t0.addingTimeInterval(5 * 5))   // first failing sample

    let recovery = feed(&d, (8..<12).map { healthy($0) })
    #expect(recovery[0].status == .outage(.isp))            // window f f f o
    #expect(recovery[1].status == .outage(.isp))            // f f f o o
    #expect(recovery[2].status == .outage(.isp))            // f f o o o  (2 failing > exit threshold)
    #expect(recovery[3].status == .healthy)                 // f o o o o: cleared, and no "degraded" tail
}

@Test func localNetworkWhenGatewayAndInternetBothFail() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    let out = feed(&d, (5..<8).map { sample($0, gw: .fail, cf: .fail, go: .fail, dns: .fail, https: .fail) })
    #expect(out[2].status == .outage(.localNetwork))
}

@Test func dnsOnlyFailure() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    let out = feed(&d, (5..<8).map { sample($0, dns: .fail) })
    #expect(out[2].status == .outage(.dns))
}

@Test func webPathFailure() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    let out = feed(&d, (5..<8).map { sample($0, https: .fail) })
    #expect(out[2].status == .outage(.webPath))
}

@Test func causeShiftsWithinOutageButSinceIsKept() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    // starts as DNS-only, then the whole internet goes
    feed(&d, (5..<8).map { sample($0, dns: .fail) })
    let out = feed(&d, (8..<12).map { sample($0, cf: .fail, go: .fail, dns: .fail, https: .fail) })
    #expect(out.last?.status == .outage(.isp))
    #expect(out.last?.since == t0.addingTimeInterval(5 * 5))
}

// MARK: - ICMP-blocked router

@Test func unavailableGatewayIsNotAnOutage() {
    var d = Diagnoser()
    for diag in feed(&d, (0..<10).map { i in
        sample(i, gw: .unavailable)
    }) {
        #expect(diag.status == .healthy)
    }
}

@Test func routerThatDropsPingIsNotLocalOutageAndIsFlaggedAfterTen() {
    var d = Diagnoser()
    let out = feed(&d, (0..<14).map { sample($0, gw: .fail) })
    for diag in out {
        if case .outage = diag.status { Issue.record("router ICMP drop must not be an outage") }
    }
    #expect(out[8].gatewayIcmpBlocked == false)
    #expect(out[9].gatewayIcmpBlocked == true)
    #expect(out.last?.status == .healthy)       // gateway loss is ignored once known blocked
}

@Test func blockedRouterStillDetectsRealIspOutage() {
    var d = Diagnoser()
    feed(&d, (0..<12).map { sample($0, gw: .fail) })
    let out = feed(&d, (12..<15).map { sample($0, gw: .fail, cf: .fail, go: .fail, dns: .fail, https: .fail) })
    #expect(out[2].status == .outage(.isp))
    #expect(out[2].gatewayIcmpBlocked)
}

// MARK: - Path changes

@Test func interfaceChangeResetsWindow() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    feed(&d, (5..<7).map { sample($0, iface: .wifi, https: .fail) })        // 2 failures on Wi-Fi
    let diag = d.ingest(sample(7, iface: .ethernet, https: .fail))          // 1 more, on Ethernet
    if case .outage = diag.status { Issue.record("failures across a path change must not be combined") }
}

@Test func baselinesAreKeptPerInterface() {
    var d = Diagnoser()
    feed(&d, (0..<70).map { healthy($0) })
    #expect(d.baselineP95(.wifi, .cloudflare) != nil)
    #expect(d.baselineP95(.vpn, .cloudflare) == nil)
}

// MARK: - Degraded

@Test func lossMakesDegradedThenAgesOut() {
    var d = Diagnoser()
    feed(&d, (0..<6).map { healthy($0) })
    let a = d.ingest(sample(6, https: .fail))
    #expect(a.status == .healthy)                             // one lost sample alone is not flagged
    let b = d.ingest(sample(7, https: .fail))
    #expect(b.status == .degraded([.loss(.https)]))
    #expect(b.since == t0.addingTimeInterval(7 * 5))
    // fails at i=6,7 age out of the 30s window by i=14
    var last = b
    for i in 8..<15 { last = d.ingest(healthy(i)) }
    #expect(last.status == .healthy)
    #expect(last.since == nil)
}

@Test func highLatencyDegradesOnceBaselineExists() {
    var d = Diagnoser()
    feed(&d, (0..<70).map { healthy($0) })
    let out = feed(&d, (70..<74).map { sample($0, cf: .ok(300)) })
    #expect(out[0].status == .healthy)                        // one slow sample: median still normal
    #expect(out.last?.status == .degraded([.highLatency(.cloudflare)]))
}

@Test func highLatencyIgnoredWithoutBaseline() {
    var d = Diagnoser()
    feed(&d, (0..<10).map { healthy($0) })
    let out = feed(&d, (10..<14).map { sample($0, cf: .ok(300)) })
    #expect(out.last?.status == .healthy)
}

@Test func smallAbsoluteJumpIsNotDegraded() {
    var d = Diagnoser()
    feed(&d, (0..<70).map { healthy($0) })
    // router 4ms -> 20ms is >3x baseline but only +16ms, under the floor
    let out = feed(&d, (70..<75).map { sample($0, gw: .ok(20)) })
    #expect(out.last?.status == .healthy)
}

@Test func degradedSamplesDoNotPolluteBaseline() {
    var d = Diagnoser()
    feed(&d, (0..<70).map { healthy($0) })
    let before = d.baselineP95(.wifi, .cloudflare)
    feed(&d, (70..<90).map { sample($0, cf: .ok(300)) })
    #expect(d.baselineP95(.wifi, .cloudflare) == before)
}

// MARK: - Slow cadence

@Test func highLatencyIsStillDetectedAtTheThirtySecondCadence() {
    var d = Diagnoser()
    // 70 samples 30 s apart build the baseline; then the 1.1.1.1 ping goes from about 22 ms to 300 ms
    feed(&d, (0..<70).map { sample($0, step: 30, cf: .ok(20 + Double($0 % 5))) })
    let out = feed(&d, (70..<74).map { sample($0, step: 30, cf: .ok(300)) })
    #expect(out.last?.status == .degraded([.highLatency(.cloudflare)]))
    #expect(out.first?.status == .healthy)                    // one slow sample is not enough
}

// MARK: - Gaps in sampling

@Test func resetAfterGapForgetsAnOutageAndStaleFailures() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    let out = feed(&d, (5..<8).map { sample($0, cf: .fail, go: .fail, dns: .fail, https: .fail) })
    #expect(out.last?.status == .outage(.isp))
    d.resetAfterGap()
    let after = d.ingest(healthy(100))
    #expect(after.status == .healthy)
    #expect(after.since == nil)
}

@Test func failuresBeforeAGapDoNotCountTowardsAnOutageAfterIt() {
    var d = Diagnoser()
    feed(&d, (0..<5).map { healthy($0) })
    feed(&d, (5..<7).map { sample($0, https: .fail) })          // two failures before the gap
    d.resetAfterGap()
    let diag = d.ingest(sample(100, https: .fail))               // one more after it: only 1 in the window
    if case .outage = diag.status { Issue.record("stale pre-gap failures must not count") }
}

@Test func baselinesSurviveAGap() {
    var d = Diagnoser()
    feed(&d, (0..<70).map { healthy($0) })
    d.resetAfterGap()
    #expect(d.baselineP95(.wifi, .cloudflare) != nil)
}

// MARK: - Determinism

@Test func replayIsDeterministic() {
    let script: [Sample] =
        (0..<30).map { healthy($0) }
        + (30..<36).map { sample($0, cf: .fail, go: .fail, dns: .fail, https: .fail) }
        + (36..<50).map { healthy($0) }
    var a = Diagnoser(), b = Diagnoser()
    #expect(feed(&a, script) == feed(&b, script))
}
