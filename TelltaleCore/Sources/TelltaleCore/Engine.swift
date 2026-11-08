import Foundation

/// Wires Sampler -> Store + Diagnoser -> Store events, and switches the Sampler to its incident
/// cadence while something is wrong. The UI reads `updates` and `latest`.
public actor Engine {
    public struct Update: Sendable, Equatable {
        public let sample: Sample
        public let diagnosis: Diagnosis
    }

    public nonisolated let updates: AsyncStream<Update>
    /// Notifications worth showing, as decided by the `NotificationPlanner`. Delivery is the app's job.
    public nonisolated let notifications: AsyncStream<AppNotification>
    public private(set) var latest: Update?
    /// Most recent storage error, if any. Storage trouble never stops sampling or diagnosis.
    public private(set) var lastError: String?

    private let continuation: AsyncStream<Update>.Continuation
    private let notificationContinuation: AsyncStream<AppNotification>.Continuation
    private var planner: NotificationPlanner
    private let sampler: Sampler
    private let store: Store
    private var diagnoser: Diagnoser
    private let maintenanceInterval: TimeInterval
    private var lastInterface: InterfaceKind?
    private var lastMaintenance: Date?
    /// Consecutive samples with nothing wrong; sampling stays fast until this reaches `settleSamples`.
    private var calmSamples = Engine.settleSamples
    private var consumer: Task<Void, Never>?

    public init(sampler: Sampler, store: Store, diagnoser: Diagnoser = Diagnoser(),
                maintenanceInterval: TimeInterval = 300,
                notificationSettings: NotificationSettings = NotificationSettings()) {
        var cont: AsyncStream<Update>.Continuation!
        updates = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { cont = $0 }
        continuation = cont
        var notificationCont: AsyncStream<AppNotification>.Continuation!
        notifications = AsyncStream(bufferingPolicy: .bufferingNewest(16)) { notificationCont = $0 }
        notificationContinuation = notificationCont
        planner = NotificationPlanner(settings: notificationSettings)
        self.sampler = sampler
        self.store = store
        self.diagnoser = diagnoser
        self.maintenanceInterval = maintenanceInterval
    }

    public func start() async {
        if consumer == nil {
            let samples = sampler.samples
            consumer = Task { for await s in samples { await self.handle(s) } }
        }
        await sampler.start()
    }

    /// Apply the user's notification preferences; takes effect from the next sample.
    public func setNotificationSettings(_ settings: NotificationSettings) {
        planner.settings = settings
    }

    /// Pause sampling (system sleep, user pause). `start()` resumes. Monitoring is blind while paused, so any
    /// open outage or degraded event is closed now and the Diagnoser starts fresh on resume.
    public func pause(at now: Date = Date()) async {
        await sampler.pause()
        diagnoser.resetAfterGap()
        planner.reset()                                       // an outage "ending" across a gap is not good news
        record { try store.apply(Diagnosis(status: .healthy, since: nil, gatewayIcmpBlocked: false), at: now) }
    }

    public func stop() async {
        await sampler.stop()
        consumer?.cancel()
        consumer = nil
        continuation.finish()
        notificationContinuation.finish()
    }

    private func handle(_ s: Sample) async {
        record { try store.insert(s) }
        if let last = lastInterface, last != s.interface {
            record { try store.recordPathChange(from: last, to: s.interface, at: s.ts) }
        }
        lastInterface = s.interface

        let diagnosis = diagnoser.ingest(s)
        record { try store.apply(diagnosis, at: s.ts) }
        calmSamples = (diagnosis.status != .healthy || Self.isSuspect(s, diagnosis)) ? 0 : calmSamples + 1
        await sampler.setIncident(calmSamples < Self.settleSamples)
        for notification in planner.ingest(diagnosis, at: s.ts) { notificationContinuation.yield(notification) }

        if lastMaintenance.map({ s.ts.timeIntervalSince($0) >= maintenanceInterval }) ?? true {
            lastMaintenance = s.ts
            record { try store.maintain(now: s.ts) }
        }

        let update = Update(sample: s, diagnosis: diagnosis)
        latest = update
        continuation.yield(update)
    }

    /// Samples at the fast cadence after the last sign of trouble before falling back to the slow one.
    static let settleSamples = 10

    /// Any sign of trouble, even before the Diagnoser's hysteresis agrees. It switches to the fast cadence
    /// at once, so a problem noticed at the slow pace is confirmed or dismissed within seconds. A gateway ping
    /// that fails while the internet answers is a router ignoring ICMP, not trouble.
    static func isSuspect(_ s: Sample, _ d: Diagnosis) -> Bool {
        let internetOk = s.cloudflare.latency != nil || s.google.latency != nil
        let gatewayExcused = d.gatewayIcmpBlocked || internetOk
        return ProbeKind.allCases.contains { kind in
            s[kind].isFail && !(kind == .gateway && gatewayExcused)
        }
    }

    private func record(_ work: () throws -> Void) {
        do { try work() } catch { lastError = String(describing: error) }
    }
}
