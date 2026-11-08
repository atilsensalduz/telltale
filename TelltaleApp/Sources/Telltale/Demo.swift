import Foundation
import TelltaleCore

/// Scripted network for eyeballing every UI state without breaking the real connection.
/// Enable with TELLTALE_DEMO=1. One tick per second; the cycle repeats every 100 ticks:
///   0-39 healthy | 40-47 ISP outage | 48-64 healthy | 65-72 DNS outage | 73-84 healthy | 85-99 HTTPS packet loss
enum DemoSampler {
    private struct Env: NetworkEnvironment {
        func snapshot() -> ProbeEnvironment { ProbeEnvironment(gateway: "192.168.1.1", interface: .wifi) }
    }

    private struct Wifi: WifiSource {
        func read() -> WifiStats? {
            let wobble = Int((3 * sin(Date().timeIntervalSinceReferenceDate / 7)).rounded())
            return WifiStats(rssi: -42 + wobble, noise: -95, channel: 44, txRateMbps: 1200)
        }
    }

    private final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; let v = n; n += 1; return v }
    }

    private struct ScriptedProbe: Probe {
        let kind: ProbeKind
        let base: Double
        let ticks = Ticks()

        func run(_ env: ProbeEnvironment) async -> ProbeOutput {
            let tick = ticks.next() % 100
            let jitter = 1 + 0.15 * sin(Double(tick) * 1.7)
            let ok = ProbeResult.ok(base * jitter)
            switch tick {
            case 40..<48 where kind != .gateway: return ProbeOutput(.fail)                    // ISP outage
            case 65..<73 where kind == .dns: return ProbeOutput(.fail)                        // DNS outage
            case 85..<100 where kind == .https && tick % 3 == 1: return ProbeOutput(.fail)    // packet loss
            default: return ProbeOutput(ok)
            }
        }
    }

    static func make() -> Sampler {
        var config = SamplerConfig()
        config.normalInterval = 1
        config.incidentInterval = 1
        let probes: [any Probe] = [
            ScriptedProbe(kind: .gateway, base: 5), ScriptedProbe(kind: .cloudflare, base: 6),
            ScriptedProbe(kind: .google, base: 6), ScriptedProbe(kind: .dns, base: 40),
            ScriptedProbe(kind: .https, base: 280),
        ]
        return Sampler(probes: probes, environment: Env(), wifi: Wifi(), config: config)
    }
}
