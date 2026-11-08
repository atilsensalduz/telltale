import Foundation
import Testing
@testable import TelltaleCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private func outage(_ cause: Cause = .isp, since: TimeInterval) -> Diagnosis {
    Diagnosis(status: .outage(cause), since: at(since), gatewayIcmpBlocked: false)
}
private func degraded(since: TimeInterval, _ reasons: [DegradeReason] = [.highLatency(.https)]) -> Diagnosis {
    Diagnosis(status: .degraded(reasons), since: at(since), gatewayIcmpBlocked: false)
}
private let healthy = Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false)

private func planner(_ settings: NotificationSettings = NotificationSettings()) -> NotificationPlanner {
    NotificationPlanner(settings: settings, time: { "T\(Int($0.timeIntervalSince(t0)))" })
}

// MARK: - Outages

@Test func healthyNeverNotifies() {
    var p = planner()
    #expect((0..<10).flatMap { p.ingest(healthy, at: at(Double($0) * 5)) }.isEmpty)
}

@Test func anOutageIsAnnouncedOnceWithSound() {
    var p = planner()
    let first = p.ingest(outage(since: 0), at: at(10))
    #expect(first.count == 1)
    let n = first[0]
    #expect(n.kind == .outageStart)
    #expect(n.title == "ISP / upstream is down")
    #expect(n.body == "Since T0. The router answers, but 1.1.1.1 and 8.8.8.8 don't.")
    #expect(n.sound)
    #expect(n.eventStart == at(0))
    #expect(p.ingest(outage(since: 0), at: at(15)).isEmpty)
    #expect(p.ingest(outage(.dns, since: 0), at: at(20)).isEmpty)        // the cause shifting is not news
}

@Test func recoveryIsAnnouncedSilentlyWithTheDuration() {
    var p = planner()
    _ = p.ingest(outage(since: 0), at: at(10))
    let end = p.ingest(healthy, at: at(185))
    #expect(end.count == 1)
    #expect(end[0].kind == .outageEnd)
    #expect(end[0].title == "Back online")
    #expect(end[0].body == "ISP / upstream was down for 3 min (T0 to T185).")
    #expect(!end[0].sound)
    #expect(end[0].eventStart == at(0))
    #expect(p.ingest(healthy, at: at(190)).isEmpty)
}

@Test func anOutageThatClearsIntoDegradedStillCountsAsEnded() {
    var p = planner()
    _ = p.ingest(outage(since: 0), at: at(10))
    let out = p.ingest(degraded(since: 100), at: at(100))
    #expect(out.map(\.kind) == [.outageEnd])
}

// MARK: - Settings

@Test func settingsSwitchEachNotificationOff() {
    var noStart = planner({ var s = NotificationSettings(); s.outageStart = false; return s }())
    #expect(noStart.ingest(outage(since: 0), at: at(10)).isEmpty)
    #expect(noStart.ingest(healthy, at: at(100)).map(\.kind) == [.outageEnd])    // the end is its own switch

    var noEnd = planner({ var s = NotificationSettings(); s.outageEnd = false; return s }())
    #expect(noEnd.ingest(outage(since: 0), at: at(10)).map(\.kind) == [.outageStart])
    #expect(noEnd.ingest(healthy, at: at(100)).isEmpty)

    var silent = planner({ var s = NotificationSettings(); s.outageSound = false; return s }())
    #expect(silent.ingest(outage(since: 0), at: at(10)).first?.sound == false)
}

// MARK: - Quality drops

@Test func degradedIsAnnouncedOnlyAfterTwoMinutesAndOnlyOnce() {
    var p = planner()
    #expect(p.ingest(degraded(since: 0), at: at(5)).isEmpty)
    #expect(p.ingest(degraded(since: 0), at: at(60)).isEmpty)
    let n = p.ingest(degraded(since: 0), at: at(120))
    #expect(n.count == 1)
    #expect(n[0].kind == .qualityDrop)
    #expect(n[0].title == "HTTPS is slower than usual")
    #expect(n[0].body == "For 2 min so far. Not an outage.")
    #expect(!n[0].sound)
    #expect(n[0].eventStart == at(0))
    #expect(p.ingest(degraded(since: 0), at: at(180)).isEmpty)
}

@Test func aNewDegradedStretchStartsItsOwnTimer() {
    var p = planner()
    _ = p.ingest(degraded(since: 0), at: at(130))
    #expect(p.ingest(healthy, at: at(200)).isEmpty)                      // ending a quality drop is silent
    #expect(p.ingest(degraded(since: 500), at: at(560)).isEmpty)
    #expect(p.ingest(degraded(since: 500), at: at(620)).map(\.kind) == [.qualityDrop])
}

@Test func degradedCanBeSwitchedOffAndAnOutageSupersedesIt() {
    var off = planner({ var s = NotificationSettings(); s.qualityDrop = false; return s }())
    #expect(off.ingest(degraded(since: 0), at: at(300)).isEmpty)

    var p = planner()
    #expect(p.ingest(degraded(since: 0), at: at(60)).isEmpty)
    #expect(p.ingest(outage(since: 70), at: at(75)).map(\.kind) == [.outageStart])
    #expect(p.ingest(outage(since: 70), at: at(200)).isEmpty)            // no quality drop for the earlier stretch
}

// MARK: - Flapping

@Test func aFlappingConnectionIsOneUnstableNoticeAndOneSummary() {
    var p = planner()
    #expect(p.ingest(outage(since: 0), at: at(10)).map(\.kind) == [.outageStart])
    #expect(p.ingest(healthy, at: at(100)).map(\.kind) == [.outageEnd])           // "Back online"

    let flap = p.ingest(outage(since: 125), at: at(130))
    #expect(flap.map(\.kind) == [.unstable])
    #expect(flap[0].title == "ISP / upstream is unstable")
    #expect(flap[0].body == "Down again 25 s after it recovered.")
    #expect(!flap[0].sound)

    #expect(p.ingest(healthy, at: at(200)).isEmpty)                               // suppressed from here on
    #expect(p.ingest(outage(since: 225), at: at(230)).isEmpty)
    #expect(p.ingest(healthy, at: at(300)).isEmpty)
    #expect(p.ingest(healthy, at: at(350)).isEmpty)                               // only 50 s of calm so far

    let summary = p.ingest(healthy, at: at(420))
    #expect(summary.count == 1)
    #expect(summary[0].title == "ISP / upstream is stable again")
    #expect(summary[0].body == "ISP / upstream dropped 3 times between T0 and T300, 4 min down in total.")
    #expect(summary[0].eventStart == at(0))
    #expect(p.ingest(healthy, at: at(430)).isEmpty)                               // announced once
}

@Test func aDifferentCauseOrALongGapIsANewOutageNotAFlap() {
    var p = planner()
    _ = p.ingest(outage(since: 0), at: at(10))
    _ = p.ingest(healthy, at: at(100))
    #expect(p.ingest(outage(.dns, since: 120), at: at(125)).map(\.kind) == [.outageStart])   // other cause

    var q = planner()
    _ = q.ingest(outage(since: 0), at: at(10))
    _ = q.ingest(healthy, at: at(100))
    #expect(q.ingest(outage(since: 300), at: at(305)).map(\.kind) == [.outageStart])         // 200 s later
}

@Test func aNewOutageWhileAnUnstableStretchIsPendingFlushesItsSummary() {
    var p = planner()
    _ = p.ingest(outage(since: 0), at: at(10))
    _ = p.ingest(healthy, at: at(100))
    _ = p.ingest(outage(since: 125), at: at(130))
    _ = p.ingest(healthy, at: at(200))
    let out = p.ingest(outage(.dns, since: 220), at: at(225))                     // different cause, within the window
    #expect(out.map(\.kind) == [.outageEnd, .outageStart])
    #expect(out[0].title == "ISP / upstream is stable again")
}

// MARK: - Pause and sleep

@Test func resetForgetsEverythingWithoutNotifying() {
    var p = planner()
    _ = p.ingest(outage(since: 0), at: at(10))
    p.reset()
    #expect(p.ingest(healthy, at: at(500)).isEmpty)                               // no "Back online" across a gap
    #expect(p.ingest(outage(since: 600), at: at(605)).map(\.kind) == [.outageStart])
}
