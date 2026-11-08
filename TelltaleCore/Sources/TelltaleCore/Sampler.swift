import Foundation

public struct SamplerConfig: Sendable {
    /// Seconds between ticks while everything is fine. The Engine drops to `incidentInterval` as soon as
    /// anything looks wrong, so a problem noticed at this pace is confirmed within seconds.
    public var normalInterval: TimeInterval = 30
    /// Cadence while the Diagnoser reports a problem.
    public var incidentInterval: TimeInterval = 1
    /// Backstop per probe; the probes also have their own, shorter, timeouts.
    public var probeTimeout: TimeInterval = 6
    public init() {}
}

/// Runs all probes concurrently on a schedule and emits one `Sample` per tick.
/// Ticks are sequential: a slow tick delays the next one rather than overlapping it.
public actor Sampler {
    public nonisolated let samples: AsyncStream<Sample>

    private let continuation: AsyncStream<Sample>.Continuation
    private let probes: [any Probe]
    private let environment: any NetworkEnvironment
    private let wifi: (any WifiSource)?
    private let config: SamplerConfig
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var task: Task<Void, Never>?
    private var incident = false
    private var finished = false

    public init(
        probes: [any Probe],
        environment: any NetworkEnvironment,
        wifi: (any WifiSource)? = nil,
        config: SamplerConfig = SamplerConfig(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        var cont: AsyncStream<Sample>.Continuation!
        samples = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        continuation = cont
        self.probes = probes
        self.environment = environment
        self.wifi = wifi
        self.config = config
        self.now = now
        self.sleep = sleep
    }

    /// The real probe set from the plan: gateway, 1.1.1.1, 8.8.8.8, DNS to 1.1.1.1, fresh HTTPS.
    public static func live(config: SamplerConfig = SamplerConfig()) -> Sampler {
        Sampler(
            probes: [
                ICMPProbe(kind: .gateway, target: .gateway),
                ICMPProbe(kind: .cloudflare, target: .host("1.1.1.1")),
                ICMPProbe(kind: .google, target: .host("8.8.8.8")),
                DNSProbe(),
                HTTPSProbe(),
            ],
            environment: SystemNetworkEnvironment(),
            wifi: CoreWLANSource(),
            config: config)
    }

    // MARK: - Lifecycle

    /// Starts (or resumes) sampling. Idempotent. The first tick runs immediately.
    public func start() {
        guard task == nil, !finished else { return }
        task = Task { await self.loop() }
    }

    /// Stops ticking but keeps the stream open (system sleep, user pause). `start()` resumes.
    public func pause() {
        task?.cancel()
        task = nil
    }

    /// Ends the stream for good.
    public func stop() {
        pause()
        finished = true
        continuation.finish()
    }

    /// Switches between the normal and incident cadence.
    public func setIncident(_ on: Bool) { incident = on }

    private func loop() async {
        while !Task.isCancelled {
            let started = now()
            let sample = await sampleOnce()
            if Task.isCancelled { break }          // paused mid-tick: drop the stale sample
            continuation.yield(sample)
            let interval = incident ? config.incidentInterval : config.normalInterval
            let wait = max(0, interval - now().timeIntervalSince(started))
            do { try await sleep(wait) } catch { break }
        }
    }

    // MARK: - One tick

    /// Runs every probe once, concurrently, and assembles the sample. A probe that does not
    /// finish within `probeTimeout` counts as failed; a probe that is not configured is unavailable.
    public func sampleOnce() async -> Sample {
        let ts = now()
        let env = environment.snapshot()
        let timeout = config.probeTimeout
        let outputs: [ProbeKind: ProbeOutput] = await withTaskGroup(of: (ProbeKind, ProbeOutput).self) { group in
            for probe in probes {
                group.addTask {
                    let out = await Self.withTimeout(timeout) { await probe.run(env) }
                    return (probe.kind, out ?? ProbeOutput(.fail))
                }
            }
            var all: [ProbeKind: ProbeOutput] = [:]
            for await (kind, out) in group { all[kind] = out }
            return all
        }
        func result(_ k: ProbeKind) -> ProbeResult { outputs[k]?.result ?? .unavailable }
        return Sample(
            ts: ts, interface: env.interface,
            gateway: result(.gateway), cloudflare: result(.cloudflare), google: result(.google),
            dns: result(.dns), https: result(.https),
            httpsBreakdown: outputs[.https]?.httpsBreakdown,
            // Wi-Fi stats only describe the path in use when Wi-Fi carries the default route.
            wifi: env.interface == .wifi ? wifi?.read() : nil)
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                         _ op: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
