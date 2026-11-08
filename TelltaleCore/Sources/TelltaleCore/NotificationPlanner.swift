import Foundation

public struct NotificationSettings: Equatable, Sendable {
    public var outageStart = true
    /// Sound for the outage-start notification only; everything else is silent.
    public var outageSound = true
    /// Covers "back online" and the summary after an unstable stretch.
    public var outageEnd = true
    public var qualityDrop = true
    /// How long quality must stay degraded before anyone is told.
    public var degradedAfter: TimeInterval = 120
    /// An outage of the same cause starting this soon after one ended belongs to the same unstable stretch.
    public var coalesceWindow: TimeInterval = 120
    public init() {}
}

public struct AppNotification: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case outageStart, outageEnd, qualityDrop, unstable }
    public var kind: Kind
    /// Stable per event, so a repeat replaces instead of stacking.
    public var id: String
    public var title: String
    public var body: String
    public var sound: Bool
    /// When the event this is about began, so a click can open the History window there.
    public var eventStart: Date
}

/// Decides what to tell the user. Pure: feed it each `Diagnosis` with its time and it returns the
/// notifications to show, if any. Hysteresis is already in the Diagnoser; this layer adds restraint.
public struct NotificationPlanner: Sendable {
    public var settings: NotificationSettings
    private let time: @Sendable (Date) -> String

    private struct OpenOutage { var cause: Cause; var since: Date }
    /// Outages of one cause close together. `count` 1 is an ordinary outage; 2 or more is a flapping connection.
    private struct Episode { var cause: Cause; var start: Date; var count: Int; var downtime: TimeInterval; var lastEnd: Date? }

    private var outage: OpenOutage?
    private var episode: Episode?
    private var degradedSince: Date?
    private var degradedAnnounced = false

    public init(settings: NotificationSettings = NotificationSettings(),
                time: @escaping @Sendable (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) {
        self.settings = settings
        self.time = time
    }

    /// Forget everything without notifying. For sleep and pause: monitoring was blind, so an outage that
    /// "ended" across the gap is unknown, not good news.
    public mutating func reset() {
        outage = nil; episode = nil
        degradedSince = nil; degradedAnnounced = false
    }

    public mutating func ingest(_ d: Diagnosis, at now: Date) -> [AppNotification] {
        var out: [AppNotification] = []
        switch d.status {
        case .outage(let cause):
            degradedSince = nil; degradedAnnounced = false
            if outage == nil {
                let since = d.since ?? now
                outage = OpenOutage(cause: cause, since: since)
                out += outageStarted(cause, since: since, now: now)
            } else {
                outage?.cause = cause                       // the cause shifting mid-outage is not news
            }
        case .degraded:
            if let o = outage { out += outageEnded(o, now: now); outage = nil }
            out += trackDegraded(d, now: now)
            out += settleEpisode(now: now)
        case .healthy:
            if let o = outage { out += outageEnded(o, now: now); outage = nil }
            degradedSince = nil; degradedAnnounced = false
            out += settleEpisode(now: now)
        }
        return out
    }

    // MARK: - Outages

    private mutating func outageStarted(_ cause: Cause, since: Date, now: Date) -> [AppNotification] {
        var out: [AppNotification] = []
        if var ep = episode {
            if ep.cause == cause, let end = ep.lastEnd, since.timeIntervalSince(end) <= settings.coalesceWindow {
                ep.count += 1
                ep.lastEnd = nil
                episode = ep
                // Only the first flap is announced; the summary covers the rest.
                guard ep.count == 2, settings.outageStart else { return [] }
                return [AppNotification(
                    kind: .unstable, id: "unstable-\(Int(ep.start.timeIntervalSince1970))",
                    title: "\(cause.rawValue) is unstable",
                    body: "Down again \(History.shortDuration(since.timeIntervalSince(end))) after it recovered.",
                    sound: false, eventStart: since)]
            }
            out += closeEpisode(at: ep.lastEnd ?? now)       // an older unstable stretch ends here
        }
        episode = Episode(cause: cause, start: since, count: 1, downtime: 0, lastEnd: nil)
        guard settings.outageStart else { return out }
        out.append(AppNotification(
            kind: .outageStart, id: "outage-\(Int(since.timeIntervalSince1970))",
            title: "\(cause.rawValue) is down",
            body: "Since \(time(since)). \(PopoverContent.evidence(for: cause))",
            sound: settings.outageSound, eventStart: since))
        return out
    }

    private mutating func outageEnded(_ o: OpenOutage, now: Date) -> [AppNotification] {
        guard var ep = episode else { return [] }
        ep.downtime += max(0, now.timeIntervalSince(o.since))
        ep.lastEnd = now
        episode = ep
        if ep.count >= 2 { return [] }                       // part of an unstable stretch: summarised later
        guard settings.outageEnd else { return [] }
        return [AppNotification(
            kind: .outageEnd, id: "outage-end-\(Int(o.since.timeIntervalSince1970))",
            title: "Back online",
            body: "\(o.cause.rawValue) was down for \(History.shortDuration(now.timeIntervalSince(o.since))) "
                + "(\(time(o.since)) to \(time(now))).",
            sound: false, eventStart: o.since)]
    }

    /// Once nothing has failed for the coalesce window, an unstable stretch gets one closing summary.
    private mutating func settleEpisode(now: Date) -> [AppNotification] {
        guard let ep = episode, outage == nil, let end = ep.lastEnd,
              now.timeIntervalSince(end) >= settings.coalesceWindow else { return [] }
        return closeEpisode(at: end)
    }

    private mutating func closeEpisode(at end: Date) -> [AppNotification] {
        guard let ep = episode else { return [] }
        episode = nil
        guard ep.count >= 2, settings.outageEnd else { return [] }
        return [AppNotification(
            kind: .outageEnd, id: "episode-\(Int(ep.start.timeIntervalSince1970))",
            title: "\(ep.cause.rawValue) is stable again",
            body: "\(ep.cause.rawValue) dropped \(ep.count) times between \(time(ep.start)) and \(time(end)), "
                + "\(History.shortDuration(ep.downtime)) down in total.",
            sound: false, eventStart: ep.start)]
    }

    // MARK: - Quality

    private mutating func trackDegraded(_ d: Diagnosis, now: Date) -> [AppNotification] {
        let since = d.since ?? now
        if degradedSince == nil { degradedSince = since; degradedAnnounced = false }
        guard settings.qualityDrop, !degradedAnnounced, let start = degradedSince,
              now.timeIntervalSince(start) >= settings.degradedAfter else { return [] }
        degradedAnnounced = true
        let banner = PopoverContent.banner(diagnosis: d, now: now, time: time)
        return [AppNotification(
            kind: .qualityDrop, id: "quality-\(Int(start.timeIntervalSince1970))",
            title: banner.title,
            body: "For \(History.shortDuration(now.timeIntervalSince(start))) so far. Not an outage.",
            sound: false, eventStart: start)]
    }
}
