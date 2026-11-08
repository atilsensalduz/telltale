import Foundation
import Testing
@testable import TelltaleCore

// MARK: - Fakes

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Returns the current value, then increments.
    func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Deterministic clock: time only moves when the Sampler sleeps. Each sleep also waits a few real
/// milliseconds so the sampler cannot outrun a consumer.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: Date
    private var recorded: [TimeInterval] = []
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { t = start }

    func read() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    var now: @Sendable () -> Date { { [self] in read() } }
    var sleeps: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return recorded }

    private func advance(_ s: TimeInterval) {
        lock.lock(); t = t.addingTimeInterval(s); recorded.append(s); lock.unlock()
    }
    func sleep(_ s: TimeInterval) async throws {
        advance(s)
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}

private struct FixedEnv: NetworkEnvironment {
    var env = ProbeEnvironment(gateway: "192.168.1.1", interface: .wifi)
    func snapshot() -> ProbeEnvironment { env }
}

/// Wi-Fi for the first `switchAfter` snapshots, then Ethernet.
private struct SwitchingEnv: NetworkEnvironment {
    let switchAfter: Int
    let calls = Counter()
    func snapshot() -> ProbeEnvironment {
        ProbeEnvironment(gateway: "192.168.1.1", interface: calls.next() < switchAfter ? .wifi : .ethernet)
    }
}

private struct FakeWifi: WifiSource {
    func read() -> WifiStats? { WifiStats(rssi: -40, noise: -95, channel: 44, txRateMbps: 1000) }
}

private struct ScriptedProbe: Probe {
    let kind: ProbeKind
    let calls = Counter()
    let script: @Sendable (Int) -> ProbeResult
    func run(_ env: ProbeEnvironment) async -> ProbeOutput { ProbeOutput(script(calls.next())) }
}

private struct HangingProbe: Probe {
    let kind: ProbeKind
    func run(_ env: ProbeEnvironment) async -> ProbeOutput {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return ProbeOutput(.ok(1))
    }
}

private func allProbes(_ script: @escaping @Sendable (ProbeKind, Int) -> ProbeResult) -> [ScriptedProbe] {
    ProbeKind.allCases.map { k in ScriptedProbe(kind: k) { script(k, $0) } }
}

private func makeSampler(_ clock: FakeClock, probes: [any Probe], env: any NetworkEnvironment = FixedEnv(),
                         wifi: (any WifiSource)? = nil, config: SamplerConfig = SamplerConfig()) -> Sampler {
    Sampler(probes: probes, environment: env, wifi: wifi, config: config,
            now: clock.now, sleep: { try await clock.sleep($0) })
}

// MARK: - Packet helpers

@Test func echoRequestHasValidChecksumAndHeader() {
    let p = ICMPPacket.echoRequest(id: 0xBEEF, seq: 7)
    #expect(p.count == 16)
    #expect(p[0] == 8 && p[1] == 0)
    #expect(Array(p[4...7]) == [0xBE, 0xEF, 0x00, 0x07])
    #expect(ICMPPacket.checksum(p) == 0)          // checksum over a valid packet folds to zero
}

@Test func echoReplyDetection() {
    let reply: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]
    #expect(ICMPPacket.isEchoReply(reply))
    #expect(ICMPPacket.isEchoReply([0x45] + [UInt8](repeating: 0, count: 19) + reply))   // IPv4 header first
    var request = reply; request[0] = 8
    #expect(!ICMPPacket.isEchoReply(request))
    #expect(!ICMPPacket.isEchoReply([0, 0, 0]))
    #expect(!ICMPPacket.isEchoReply([]))
}

@Test func dnsQueryBytes() {
    #expect(DNSPacket.query(name: "a.com", id: 0x1234) ==
            [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0,
             1, 0x61, 3, 0x63, 0x6f, 0x6d, 0, 0, 1, 0, 1])
}

@Test func dnsResponseMustMatchIdAndHaveQRBit() {
    var r = [UInt8](repeating: 0, count: 12)
    r[0] = 0x12; r[1] = 0x34; r[2] = 0x81; r[3] = 0x83     // QR set, RCODE 3 (NXDOMAIN) still counts
    #expect(DNSPacket.isResponse(r, id: 0x1234))
    #expect(!DNSPacket.isResponse(r, id: 0x1235))
    r[2] = 0x01
    #expect(!DNSPacket.isResponse(r, id: 0x1234))           // a query, not a response
    #expect(!DNSPacket.isResponse([0x12, 0x34], id: 0x1234))
}

@Test func interfaceClassification() {
    #expect(InterfaceClassifier.kind(bsdName: "en0", scType: "IEEE80211", wifiName: "en0") == .wifi)
    #expect(InterfaceClassifier.kind(bsdName: "en0", scType: nil, wifiName: "en0") == .wifi)
    #expect(InterfaceClassifier.kind(bsdName: "en2", scType: "Ethernet", wifiName: "en0") == .ethernet)
    #expect(InterfaceClassifier.kind(bsdName: "utun4", scType: nil, wifiName: "en0") == .vpn)
    #expect(InterfaceClassifier.kind(bsdName: "ppp0", scType: "PPP", wifiName: nil) == .vpn)
    #expect(InterfaceClassifier.kind(bsdName: "bridge0", scType: "Bridge", wifiName: "en0") == .other)
}

// MARK: - Sampler

@Test func sampleOnceAssemblesAllProbes() async {
    let clock = FakeClock()
    let probes: [any Probe] = [
        ScriptedProbe(kind: .gateway) { _ in .ok(5) },
        ScriptedProbe(kind: .cloudflare) { _ in .ok(20) },
        ScriptedProbe(kind: .google) { _ in .fail },
        ScriptedProbe(kind: .dns) { _ in .ok(30) },
        // .https deliberately not configured
    ]
    let s = await makeSampler(clock, probes: probes, wifi: FakeWifi()).sampleOnce()
    #expect(s.gateway == .ok(5))
    #expect(s.cloudflare == .ok(20))
    #expect(s.google == .fail)
    #expect(s.dns == .ok(30))
    #expect(s.https == .unavailable)
    #expect(s.interface == .wifi)
    #expect(s.ts == clock.read())
    #expect(s.wifi?.rssi == -40)
}

@Test func wifiStatsOnlyWhenWifiIsTheDefaultRoute() async {
    let clock = FakeClock()
    let eth = FixedEnv(env: ProbeEnvironment(gateway: "10.0.0.1", interface: .ethernet))
    let s = await makeSampler(clock, probes: allProbes { _, _ in .ok(1) }, env: eth, wifi: FakeWifi()).sampleOnce()
    #expect(s.interface == .ethernet)
    #expect(s.wifi == nil)
}

@Test func hangingProbeTimesOutAsFailWithoutBlockingTheOthers() async {
    let clock = FakeClock()
    var config = SamplerConfig(); config.probeTimeout = 0.05
    let probes: [any Probe] = [ScriptedProbe(kind: .gateway) { _ in .ok(5) }, HangingProbe(kind: .https)]
    let started = Date()
    let s = await makeSampler(clock, probes: probes, config: config).sampleOnce()
    #expect(s.gateway == .ok(5))
    #expect(s.https == .fail)
    #expect(Date().timeIntervalSince(started) < 2)
}

@Test func loopEmitsOneSamplePerIntervalOnTheClock() async {
    let clock = FakeClock()
    let sampler = makeSampler(clock, probes: allProbes { _, _ in .ok(1) })
    await sampler.start()
    var it = sampler.samples.makeAsyncIterator()
    var stamps: [Date] = []
    for _ in 0..<4 { if let s = await it.next() { stamps.append(s.ts) } }
    await sampler.stop()
    #expect(stamps.count == 4)
    for (a, b) in zip(stamps, stamps.dropFirst()) { #expect(b.timeIntervalSince(a) == SamplerConfig().normalInterval) }
}

@Test func incidentCadenceIsOneSecond() async {
    let clock = FakeClock()
    let sampler = makeSampler(clock, probes: allProbes { _, _ in .ok(1) })
    await sampler.setIncident(true)
    await sampler.start()
    var it = sampler.samples.makeAsyncIterator()
    var stamps: [Date] = []
    for _ in 0..<3 { if let s = await it.next() { stamps.append(s.ts) } }
    await sampler.stop()
    for (a, b) in zip(stamps, stamps.dropFirst()) { #expect(b.timeIntervalSince(a) == 1) }
}

@Test func pauseStopsTickingAndStartResumes() async throws {
    let clock = FakeClock()
    let probe = ScriptedProbe(kind: .gateway) { _ in .ok(1) }
    let sampler = makeSampler(clock, probes: [probe])
    await sampler.start()
    try await Task.sleep(nanoseconds: 60_000_000)
    await sampler.pause()
    try await Task.sleep(nanoseconds: 60_000_000)               // let any in-flight tick drain
    let paused = probe.calls.value
    #expect(paused > 0)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(probe.calls.value == paused)                        // nothing ran while paused

    await sampler.start()
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(probe.calls.value > paused)
    await sampler.stop()
}

@Test func stopFinishesTheStream() async {
    let clock = FakeClock()
    let sampler = makeSampler(clock, probes: allProbes { _, _ in .ok(1) })
    await sampler.start()
    await sampler.stop()
    var it = sampler.samples.makeAsyncIterator()
    var guardCount = 0
    while await it.next() != nil, guardCount < 1000 { guardCount += 1 }   // drains buffered, then nil
    #expect(guardCount < 1000)
}

// MARK: - Engine

@Test func engineDiagnosesAnOutageStoresItAndSpeedsUpDuringIt() async throws {
    let clock = FakeClock()
    // ticks 0-9 healthy, 10-13 whole internet down, healthy afterwards
    let probes = allProbes { kind, tick in
        let down = (10...13).contains(tick) && kind != .gateway
        return down ? .fail : .ok(10)
    }
    let store = try Store()
    let engine = Engine(sampler: makeSampler(clock, probes: probes), store: store)
    await engine.start()

    var sawOutage = false
    var recovered = false
    var seen = 0
    for await u in engine.updates {
        seen += 1
        if u.diagnosis.status == .outage(.isp) { sawOutage = true }
        if sawOutage && u.diagnosis.status == .healthy { recovered = true; break }
        if seen > 60 { break }
    }
    await engine.stop()

    #expect(sawOutage)
    #expect(recovered)
    #expect(clock.sleeps.contains(1.0))                         // incident cadence was used
    let events = try store.events(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
    let outage = try #require(events.first { $0.kind == .outage })
    #expect(outage.cause == .isp)
    #expect(outage.end != nil)
    #expect(try store.recentSamples(limit: 5).count == 5)
    #expect(await engine.lastError == nil)
}

@Test func engineRecordsPathChanges() async throws {
    let clock = FakeClock()
    let store = try Store()
    let sampler = makeSampler(clock, probes: allProbes { _, _ in .ok(10) }, env: SwitchingEnv(switchAfter: 3))
    let engine = Engine(sampler: sampler, store: store)
    await engine.start()
    var seen = 0
    for await _ in engine.updates { seen += 1; if seen >= 6 { break } }
    await engine.stop()

    let events = try store.events(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
    let change = try #require(events.first { $0.kind == .pathChange })
    #expect(change.detail == "wifi -> ethernet")
}

@Test func engineNotifiesAtOutageStartAndEnd() async throws {
    let clock = FakeClock()
    let probes = allProbes { kind, tick in ((10...13).contains(tick) && kind != .gateway) ? .fail : .ok(10) }
    let engine = Engine(sampler: makeSampler(clock, probes: probes), store: try Store())
    await engine.start()
    let watchdog = Task { try? await Task.sleep(for: .seconds(5)); await engine.stop() }   // never hang the suite
    var kinds: [AppNotification.Kind] = []
    for await n in engine.notifications {
        kinds.append(n.kind)
        if n.kind == .outageEnd { break }
    }
    watchdog.cancel()
    await engine.stop()
    #expect(kinds == [.outageStart, .outageEnd])
}

@Test func pausingDuringAnOutageDoesNotAnnounceRecovery() async throws {
    let clock = FakeClock()
    let probes = allProbes { kind, tick in (tick >= 10 && kind != .gateway) ? .fail : .ok(10) }   // down for good
    let engine = Engine(sampler: makeSampler(clock, probes: probes), store: try Store())
    await engine.start()
    let watchdog = Task { try? await Task.sleep(for: .seconds(5)); await engine.stop() }
    var kinds: [AppNotification.Kind] = []
    for await n in engine.notifications {
        kinds.append(n.kind)
        if kinds.count == 1 {
            await engine.pause()                                 // e.g. the Mac goes to sleep
            await engine.stop()                                  // ends the stream so the loop finishes
        }
    }
    watchdog.cancel()
    #expect(kinds == [.outageStart])                             // no "Back online" for the gap
}

@Test func settingsChangeTakesEffectOnTheNextOutage() async throws {
    let clock = FakeClock()
    let probes = allProbes { kind, tick in (tick >= 10 && kind != .gateway) ? .fail : .ok(10) }
    var settings = NotificationSettings()
    settings.outageSound = false
    let engine = Engine(sampler: makeSampler(clock, probes: probes), store: try Store(), notificationSettings: settings)
    await engine.start()
    let watchdog = Task { try? await Task.sleep(for: .seconds(5)); await engine.stop() }
    var first: AppNotification?
    for await n in engine.notifications { first = n; break }
    watchdog.cancel()
    await engine.stop()
    #expect(first?.kind == .outageStart)
    #expect(first?.sound == false)
}

@Test func theSlowCadenceIsThirtySeconds() {
    #expect(SamplerConfig().normalInterval == 30)
    #expect(SamplerConfig().incidentInterval == 1)
}

@Test func aSingleFailureSpeedsUpSamplingBeforeAnyDiagnosisChanges() async throws {
    let clock = FakeClock()
    let probes = allProbes { kind, tick in (kind == .https && tick == 3) ? .fail : .ok(10) }
    let engine = Engine(sampler: makeSampler(clock, probes: probes), store: try Store())
    await engine.start()
    let watchdog = Task { try? await Task.sleep(for: .seconds(5)); await engine.stop() }
    var seen = 0
    for await u in engine.updates {
        seen += 1
        if case .outage = u.diagnosis.status { Issue.record("one failed probe is not an outage") }
        if seen >= 25 { break }
    }
    watchdog.cancel()
    await engine.stop()

    let sleeps = clock.sleeps
    #expect(sleeps.first == 30)                                 // calm at first
    #expect(sleeps.contains(1.0))                               // the failed probe triggered the fast cadence
    if let lastFast = sleeps.lastIndex(of: 1.0) {
        #expect(sleeps[(lastFast + 1)...].contains(30))         // and it settled back once nothing else failed
    }
}

@Test func aRouterThatIgnoresPingDoesNotKeepSamplingFast() {
    func sample(gw: ProbeResult, cf: ProbeResult = .ok(6), go: ProbeResult = .ok(6)) -> Sample {
        Sample(ts: Date(timeIntervalSince1970: 0), gateway: gw, cloudflare: cf, google: go, dns: .ok(40), https: .ok(280))
    }
    let healthy = Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false)
    #expect(!Engine.isSuspect(sample(gw: .fail), healthy))                       // internet answers: ICMP-shy router
    #expect(Engine.isSuspect(sample(gw: .fail, cf: .fail, go: .fail), healthy))  // the router really is gone
    #expect(Engine.isSuspect(sample(gw: .ok(5), cf: .fail), healthy))            // one public target failing counts
    #expect(!Engine.isSuspect(sample(gw: .unavailable), healthy))
}

@Test func pausingClosesTheOpenOutageEvent() async throws {
    let clock = FakeClock()
    let store = try Store()
    let probes = allProbes { kind, tick in (tick >= 10 && kind != .gateway) ? .fail : .ok(10) }   // down for good
    let engine = Engine(sampler: makeSampler(clock, probes: probes), store: store)
    await engine.start()
    var seen = 0
    for await u in engine.updates {
        seen += 1
        if u.diagnosis.status == .outage(.isp) || seen > 60 { break }
    }
    await engine.pause()

    let events = try store.events(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
    let outage = try #require(events.first { $0.kind == .outage })
    #expect(outage.end != nil)                                  // closed at the pause, not left open forever
    await engine.stop()
}
