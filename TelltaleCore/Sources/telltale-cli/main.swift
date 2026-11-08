import Foundation
import TelltaleCore

// Live smoke test of the whole engine: probes -> Diagnoser -> Store, one line per tick.
//   telltale-cli [--ticks N] [--interval SECONDS] [--db PATH]

var ticks = 5
var interval: TimeInterval = 5
var dbPath: String?
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--ticks": ticks = Int(args.popFirst() ?? "") ?? ticks
    case "--interval": interval = Double(args.popFirst() ?? "") ?? interval
    case "--db": dbPath = args.popFirst()
    default:
        print("usage: telltale-cli [--ticks N] [--interval SECONDS] [--db PATH]")
        exit(2)
    }
}

func cell(_ r: ProbeResult) -> String {
    switch r {
    case .ok(let ms): return "\(Int(ms.rounded()))ms"
    case .fail: return "FAIL"
    case .unavailable: return "-"
    }
}

func describe(_ d: Diagnosis) -> String {
    var s: String
    switch d.status {
    case .healthy: s = "ok"
    case .degraded(let r): s = "DEGRADED \(r)"
    case .outage(let c): s = "OUTAGE \(c.rawValue)"
    }
    if let since = d.since { s += " since \(since.formatted(date: .omitted, time: .standard))" }
    if d.gatewayIcmpBlocked { s += " (router ignores ping)" }
    return s
}

var config = SamplerConfig()
config.normalInterval = interval
let store = try dbPath.map { try Store(path: $0) } ?? Store()
let engine = Engine(sampler: Sampler.live(config: config), store: store)
await engine.start()

var n = 0
for await u in engine.updates {
    let s = u.sample
    let wifi = s.wifi.map { " wifi \($0.rssi)dBm ch\($0.channel)" } ?? ""
    print("\(s.ts.formatted(date: .omitted, time: .standard)) [\(s.interface.rawValue)] "
        + "gw \(cell(s.gateway)) | 1.1.1.1 \(cell(s.cloudflare)) | 8.8.8.8 \(cell(s.google)) | "
        + "dns \(cell(s.dns)) | https \(cell(s.https))\(wifi)  -> \(describe(u.diagnosis))")
    n += 1
    if n >= ticks { break }
}
await engine.stop()
if let e = await engine.lastError { print("storage error: \(e)") }
