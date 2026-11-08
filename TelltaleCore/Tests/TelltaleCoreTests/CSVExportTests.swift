import Foundation
import Testing
@testable import TelltaleCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)          // 2023-11-14T22:13:20Z
private let utc = TimeZone(identifier: "UTC")!
private let istanbul = TimeZone(identifier: "Europe/Istanbul")!      // UTC+3, no daylight saving since 2016

private func sample(_ offset: TimeInterval = 0, gw: ProbeResult = .ok(5), cf: ProbeResult = .ok(6),
                    go: ProbeResult = .ok(6), dns: ProbeResult = .ok(40), https: ProbeResult = .ok(280),
                    breakdown: HTTPSBreakdown? = nil, wifi: WifiStats? = nil) -> Sample {
    Sample(ts: t0.addingTimeInterval(offset), gateway: gw, cloudflare: cf, google: go, dns: dns, https: https,
           httpsBreakdown: breakdown, wifi: wifi)
}

// MARK: - Samples

@Test func sampleHeaderStartsWithTheNetwatchColumns() {
    let header = CSVExport.samples([], timeZone: utc)
    #expect(header == "ts,gateway,cloudflare,google,dns,https,ts_utc,interface,unavailable,"
        + "https_dns_ms,https_tcp_ms,https_tls_ms,https_ttfb_ms,wifi_rssi,wifi_noise,wifi_channel,wifi_tx_mbps\n")
}

@Test func fullSampleRow() {
    let s = sample(gw: .ok(5), cf: .ok(6.4), go: .fail, dns: .ok(40), https: .ok(280.5),
                   breakdown: HTTPSBreakdown(dnsMs: 59, tcpMs: 89.04, tlsMs: 331, ttfbMs: 89.3),
                   wifi: WifiStats(rssi: -42, noise: -96, channel: 44, txRateMbps: 1200))
    let lines = CSVExport.samples([s], timeZone: utc).split(separator: "\n").map(String.init)
    #expect(lines.count == 2)
    #expect(lines[1] == "2023-11-14T22:13:20,5.0,6.4,,40.0,280.5,2023-11-14T22:13:20Z,wifi,,59.0,89.0,331.0,89.3,-42,-96,44,1200")
}

@Test func unavailableProbesAreBlankAndListed() {
    let row = CSVExport.samples([sample(gw: .unavailable)], timeZone: utc).split(separator: "\n").map(String.init)[1]
    #expect(row == "2023-11-14T22:13:20,,6.0,6.0,40.0,280.0,2023-11-14T22:13:20Z,wifi,gateway" + String(repeating: ",", count: 8))
}

@Test func localTimeFollowsTheZoneButUtcDoesNot() {
    let row = CSVExport.samples([sample()], timeZone: istanbul).split(separator: "\n").map(String.init)[1]
    #expect(row.hasPrefix("2023-11-15T01:13:20,"))
    #expect(row.contains(",2023-11-14T22:13:20Z,"))
}

@Test func fieldQuoting() {
    #expect(CSVExport.field("plain") == "plain")
    #expect(CSVExport.field("a,b") == "\"a,b\"")
    #expect(CSVExport.field("say \"hi\"") == "\"say \"\"hi\"\"\"")
    #expect(CSVExport.field("two\nlines") == "\"two\nlines\"")
}

// MARK: - Events

@Test func closedOutageRow() {
    let e = Event(id: 1, kind: .outage, start: t0, end: t0.addingTimeInterval(185), cause: .isp, detail: nil)
    let row = CSVExport.events([e], now: t0.addingTimeInterval(999), timeZone: utc).split(separator: "\n").map(String.init)[1]
    #expect(row == "2023-11-14T22:13:20,2023-11-14T22:16:25,185,outage,ISP / upstream,,2023-11-14T22:13:20Z,2023-11-14T22:16:25Z")
}

@Test func openEventHasBlankEndAndRunsToNow() {
    let e = Event(id: 2, kind: .degraded, start: t0, end: nil, cause: nil, detail: "HTTPS loss")
    let row = CSVExport.events([e], now: t0.addingTimeInterval(60), timeZone: utc).split(separator: "\n").map(String.init)[1]
    #expect(row == "2023-11-14T22:13:20,,60,degraded,,HTTPS loss,2023-11-14T22:13:20Z,")
}

@Test func pathChangeAndQuotedDetail() {
    let change = Event(id: 3, kind: .pathChange, start: t0, end: t0, cause: nil, detail: "wifi -> ethernet")
    let odd = Event(id: 4, kind: .degraded, start: t0, end: t0, cause: nil, detail: "a, b")
    let lines = CSVExport.events([change, odd], now: t0, timeZone: utc).split(separator: "\n").map(String.init)
    #expect(lines[1] == "2023-11-14T22:13:20,2023-11-14T22:13:20,0,path_change,,wifi -> ethernet,2023-11-14T22:13:20Z,2023-11-14T22:13:20Z")
    #expect(lines[2].contains(",\"a, b\","))
}

@Test func eventHeader() {
    #expect(CSVExport.events([], now: t0, timeZone: utc) == "start,end,duration_s,kind,cause,detail,start_utc,end_utc\n")
}

// MARK: - The real netwatch.py can read it

private let netwatch = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("netwatch.py")

private func run(_ args: [String]) -> (status: Int32, out: String)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

private let pythonAvailable = FileManager.default.fileExists(atPath: netwatch.path)
    && run(["python3", "--version"])?.status == 0

@Test(.enabled(if: pythonAvailable))
func exportedSamplesLoadInNetwatchPy() throws {
    let samples = [
        sample(0, https: .ok(280.5), wifi: WifiStats(rssi: -40, noise: -95, channel: 44, txRateMbps: 1200)),
        sample(5, go: .fail, https: .fail),
        sample(10, gw: .unavailable),
    ]
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("telltale-\(UUID().uuidString).csv")
    try CSVExport.samples(samples, timeZone: utc).write(to: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: path) }

    let script = """
    import importlib.util, sys
    spec = importlib.util.spec_from_file_location("nw", sys.argv[1])
    nw = importlib.util.module_from_spec(spec); spec.loader.exec_module(nw)
    for t, v in nw.load(sys.argv[2], None):
        print(t.isoformat(), *["-" if x is None else x for x in v])
    """
    let result = try #require(run(["python3", "-I", "-c", script, netwatch.path, path.path]))
    #expect(result.status == 0)
    let lines = result.out.split(separator: "\n").map(String.init)
    #expect(lines == [
        "2023-11-14T22:13:20 5.0 6.0 6.0 40.0 280.5",
        "2023-11-14T22:13:25 5.0 6.0 - 40.0 -",
        "2023-11-14T22:13:30 - 6.0 6.0 40.0 280.0",      // unavailable reads as failed in the Python prototype
    ])
}
