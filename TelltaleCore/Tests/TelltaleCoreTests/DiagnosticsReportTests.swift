import Foundation
import Testing
@testable import TelltaleCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func sample(_ offset: TimeInterval, https: ProbeResult = .ok(280)) -> Sample {
    Sample(ts: t0.addingTimeInterval(offset), gateway: .ok(5), cloudflare: .ok(6), google: .ok(6),
           dns: .ok(40), https: https,
           wifi: WifiStats(rssi: -40, noise: -95, channel: 44, txRateMbps: 1200))
}

private func report(samples: [Sample], diagnosis: Diagnosis?, events: [Event] = [], now: Date? = nil) -> String {
    DiagnosticsReport.make(samples: samples, diagnosis: diagnosis, events: events,
                           now: now ?? samples.last?.ts ?? t0,
                           time: { "T\(Int($0.timeIntervalSince(t0)))" }, stamp: { _ in "NOW" },
                           exactTime: { "T\(Int($0.timeIntervalSince(t0)))" })
}

@Test func reportShowsStatusConnectionAndLatestValues() {
    let diag = Diagnosis(status: .outage(.isp), since: t0, gatewayIcmpBlocked: false)
    let text = report(samples: [sample(0), sample(185)], diagnosis: diag)
    #expect(text.contains("Telltale diagnostics, NOW"))
    #expect(text.contains("Status: ISP / upstream failing since T0"))
    #expect(text.contains("3 min so far."))
    #expect(text.contains("Connection: Wi-Fi: channel 44, -40 dBm, SNR 55 dB, 1200 Mbps"))
    #expect(text.contains("Latest sample (T185)"))
    #expect(text.contains("Router   5 ms"))
    #expect(text.contains("HTTPS    280 ms"))
}

@Test func reportSummarisesLossMedianAndP95PerLayer() {
    // https: 100, 200, 300, fail  -> loss 25%, median of [100,200,300] is 200, p95 is 300
    let samples = [sample(0, https: .ok(100)), sample(5, https: .ok(200)),
                   sample(10, https: .ok(300)), sample(15, https: .fail)]
    let text = report(samples: samples, diagnosis: Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false))
    #expect(text.contains("Last 30 minutes (4 samples)"))
    #expect(text.contains("HTTPS    loss 25.0%, median 200 ms, p95 300 ms"))
    #expect(text.contains("Router   loss 0.0%, median 5 ms, p95 5 ms"))
}

@Test func reportListsEventsOrSaysNone() {
    let healthy = Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false)
    #expect(report(samples: [sample(0)], diagnosis: healthy).contains("Events, last 24 h\n  none"))

    let events = [
        Event(id: 1, kind: .outage, start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(240),
              cause: .isp, detail: nil),
        Event(id: 2, kind: .degraded, start: t0.addingTimeInterval(300), end: nil, cause: nil, detail: "HTTPS loss"),
        Event(id: 4, kind: .degraded, start: t0.addingTimeInterval(320), end: t0.addingTimeInterval(330),
              cause: nil, detail: nil),
        Event(id: 3, kind: .pathChange, start: t0.addingTimeInterval(310), end: t0.addingTimeInterval(310),
              cause: nil, detail: "wifi -> ethernet"),
    ]
    let text = report(samples: [sample(0)], diagnosis: healthy, events: events, now: t0.addingTimeInterval(420))
    #expect(text.contains("T60-T240 (3 min)  outage  ISP / upstream"))
    #expect(text.contains("T300-ongoing (2 min)  degraded  HTTPS loss"))
    #expect(text.contains("T320-T330 (under a minute)  degraded\n"))    // no trailing spaces when there is no detail
    #expect(text.contains("T310  path change  wifi -> ethernet"))
}

@Test func reportBeforeAnyDataStillExplainsItself() {
    let text = report(samples: [], diagnosis: nil)
    #expect(text.contains("Status: Starting…"))
    #expect(text.contains("Last 30 minutes (0 samples)"))
    #expect(text.contains("Router   no data"))
    #expect(!text.contains("Latest sample"))
}

@Test func reportCarriesTheRouterIgnoresPingNote() {
    let diag = Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: true)
    #expect(report(samples: [sample(0)], diagnosis: diag).contains("doesn't answer ping"))
}
