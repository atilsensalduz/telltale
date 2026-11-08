import Foundation
import Testing
@testable import TelltaleCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func sample(_ offset: TimeInterval, gw: ProbeResult = .ok(5), cf: ProbeResult = .ok(6),
                    go: ProbeResult = .ok(6), dns: ProbeResult = .ok(40), https: ProbeResult = .ok(280)) -> Sample {
    Sample(ts: t0.addingTimeInterval(offset), gateway: gw, cloudflare: cf, google: go, dns: dns, https: https)
}

private func diag(_ s: Status, since: Date? = nil, blocked: Bool = false) -> Diagnosis {
    Diagnosis(status: s, since: since, gatewayIcmpBlocked: blocked)
}

// MARK: - Rows

@Test func noSamplesGivesUnavailableRowsWithEmptySparklines() {
    let rows = PopoverContent.rows(samples: [], diagnosis: nil)
    #expect(rows.map(\.kind) == ProbeKind.allCases)
    #expect(rows.allSatisfy { $0.health == .unavailable && $0.valueText == "n/a" })
    #expect(rows.allSatisfy { $0.points == Array(repeating: .gap, count: 60) })
}

@Test func rowsReflectTheLatestSample() {
    let s = sample(0, gw: .fail, cf: .ok(6.4), dns: .unavailable, https: .ok(1450))
    let rows = PopoverContent.rows(samples: [s], diagnosis: diag(.healthy))
    func row(_ k: ProbeKind) -> LayerRow { rows.first { $0.kind == k }! }
    #expect(row(.gateway).valueText == "fail" && row(.gateway).health == .failing)
    #expect(row(.cloudflare).valueText == "6 ms" && row(.cloudflare).health == .ok)
    #expect(row(.dns).valueText == "n/a" && row(.dns).health == .unavailable)
    #expect(row(.https).valueText == "1.4 s")
}

@Test func degradedReasonsMarkOnlyThoseLayersSlow() {
    let rows = PopoverContent.rows(samples: [sample(0)],
                                   diagnosis: diag(.degraded([.highLatency(.https), .loss(.dns)])))
    #expect(rows.filter { $0.health == .slow }.map(\.kind) == [.dns, .https])
    #expect(rows.filter { $0.health == .ok }.count == 3)
}

@Test func aFailingLayerStaysFailingEvenWhenFlaggedDegraded() {
    let rows = PopoverContent.rows(samples: [sample(0, https: .fail)], diagnosis: diag(.degraded([.loss(.https)])))
    #expect(rows.first { $0.kind == .https }?.health == .failing)
}

// MARK: - Sparkline

@Test func sparklineBucketsTenMinutesIntoSixtySlices() {
    let samples = (0..<60).map { i in sample(Double(i) * 10, https: i == 30 ? .fail : .ok(100 + Double(i))) }
    let pts = PopoverContent.sparkline(samples, kind: .https, span: 600, buckets: 60)
    #expect(pts.count == 60)
    #expect(pts[0] == .value(100))
    #expect(pts[29] == .value(129))
    #expect(pts[30] == .failure)
    #expect(pts[59] == .value(159))
}

@Test func sparklineBucketKeepsThePeakAndAFailureWins() {
    let spike = [sample(0, https: .ok(10)), sample(2, https: .ok(50)), sample(4, https: .ok(20))]
    #expect(PopoverContent.sparkline(spike, kind: .https, span: 60, buckets: 6).last == .value(50))
    let lossy = spike + [sample(5, https: .fail)]
    #expect(PopoverContent.sparkline(lossy, kind: .https, span: 60, buckets: 6).last == .failure)
}

@Test func sparklineLeavesGapsWhereThereIsNoData() {
    let samples = [sample(0), sample(590)]
    let pts = PopoverContent.sparkline(samples, kind: .https, span: 600, buckets: 60)
    #expect(pts[5] == .gap)
    #expect(pts[59] != .gap)
}

@Test func sparklineIgnoresSamplesOlderThanTheSpanAndUnavailableProbes() {
    let samples = [sample(0), sample(1000, https: .unavailable)]
    let pts = PopoverContent.sparkline(samples, kind: .https, span: 600, buckets: 60)
    #expect(pts == Array(repeating: .gap, count: 60))
}

// MARK: - Banner

@Test func bannerBeforeAnyData() {
    let b = PopoverContent.banner(diagnosis: nil, now: t0)
    #expect(b.style == .neutral && b.title == "Starting…")
}

@Test func healthyBanner() {
    let b = PopoverContent.banner(diagnosis: diag(.healthy), now: t0)
    #expect(b == Banner(style: .healthy, title: "All good",
                        subtitle: "Every layer is responding normally.", note: nil))
}

@Test func outageBannerNamesCauseStartAndDuration() {
    let b = PopoverContent.banner(diagnosis: diag(.outage(.isp), since: t0),
                                  now: t0.addingTimeInterval(185), time: { _ in "21:14" })
    #expect(b.style == .outage)
    #expect(b.title == "ISP / upstream failing since 21:14")
    #expect(b.subtitle == "The router answers, but 1.1.1.1 and 8.8.8.8 don't. 3 min so far.")
}

@Test func eachOutageCauseExplainsTheEvidence() {
    func sub(_ c: Cause) -> String {
        PopoverContent.banner(diagnosis: diag(.outage(c), since: t0), now: t0).subtitle
    }
    #expect(sub(.localNetwork).hasPrefix("Your router isn't answering."))
    #expect(sub(.dns).hasPrefix("Pings work, but DNS queries fail."))
    #expect(sub(.webPath).hasPrefix("Pings and DNS work, but HTTPS requests fail."))
}

@Test func degradedBannerNamesTheLayerAndSymptom() {
    func title(_ r: DegradeReason) -> String {
        PopoverContent.banner(diagnosis: diag(.degraded([r]), since: t0), now: t0).title
    }
    #expect(title(.highLatency(.https)) == "HTTPS is slower than usual")
    #expect(title(.loss(.cloudflare)) == "1.1.1.1 is dropping packets")
}

@Test func bannerCarriesTheRouterIgnoresPingNote() {
    let b = PopoverContent.banner(diagnosis: diag(.healthy, blocked: true), now: t0)
    #expect(b.note != nil)
    #expect(PopoverContent.banner(diagnosis: diag(.healthy), now: t0).note == nil)
}

// MARK: - Chart and connection line

@Test func httpsChartSplitsTheLineAtEachFailure() {
    let samples = [sample(0, https: .ok(100)), sample(10, https: .ok(120)), sample(20, https: .fail),
                   sample(30, https: .ok(90)), sample(40, https: .unavailable), sample(50, https: .ok(95))]
    let chart = PopoverContent.httpsChart(samples: samples)
    #expect(chart.points.map(\.ms) == [100, 120, 90, 95])
    #expect(chart.points.map(\.segment) == [0, 0, 1, 1])        // unavailable does not break the line
    #expect(chart.failures == [t0.addingTimeInterval(20)])
    #expect(chart.end == t0.addingTimeInterval(50))
    #expect(chart.start == t0.addingTimeInterval(50 - 1800))
}

@Test func httpsChartDropsSamplesOlderThanTheSpan() {
    let samples = [sample(0, https: .ok(1)), sample(700, https: .ok(2))]
    let chart = PopoverContent.httpsChart(samples: samples, span: 600)
    #expect(chart.points.map(\.ms) == [2])
}

@Test func httpsChartWithNoSamplesIsEmptyButHasAWindow() {
    let chart = PopoverContent.httpsChart(samples: [])
    #expect(chart.points.isEmpty && chart.failures.isEmpty)
    #expect(chart.end.timeIntervalSince(chart.start) == 1800)
}

@Test func connectionLineShowsWifiStatsOnWifi() {
    var s = sample(0)
    s.wifi = WifiStats(rssi: -38, noise: -92, channel: 44, txRateMbps: 1199.6)
    #expect(PopoverContent.connectionLine(s) == "Wi-Fi: channel 44, -38 dBm, SNR 54 dB, 1200 Mbps")
    s.wifi = nil
    #expect(PopoverContent.connectionLine(s) == "Wi-Fi: no signal data")
}

@Test func connectionLineExplainsOtherInterfaces() {
    var s = sample(0)
    s.interface = .ethernet
    #expect(PopoverContent.connectionLine(s)?.hasPrefix("Using Ethernet") == true)
    s.interface = .vpn
    #expect(PopoverContent.connectionLine(s)?.hasPrefix("Using a VPN") == true)
    s.interface = .other
    #expect(PopoverContent.connectionLine(s) == "Using an unrecognized connection.")
    #expect(PopoverContent.connectionLine(nil) == nil)
}

@Test func durationText() {
    #expect(PopoverContent.durationText(30) == "under a minute")
    #expect(PopoverContent.durationText(185) == "3 min")
    #expect(PopoverContent.durationText(3600) == "1 h")
    #expect(PopoverContent.durationText(3900) == "1 h 5 min")
    #expect(PopoverContent.durationText(-5) == "under a minute")
}
