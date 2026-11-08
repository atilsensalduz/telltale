import AppKit
import Foundation
import Observation
import ServiceManagement
import TelltaleCore

/// The one object the views observe. Owns the Engine and Store and mirrors the latest update.
@MainActor
@Observable
final class AppModel {
    private(set) var latest: Engine.Update?
    private(set) var paused = false
    /// The last 30 minutes of samples, oldest first. Feeds the sparklines and the popover chart.
    private(set) var recent: [Sample] = []
    /// Set when the history database could not be opened; Telltale keeps running without history.
    private(set) var storageError: String?
    let isDemo: Bool
    /// True for two seconds after "Copy diagnostics", so the button can confirm.
    private(set) var justCopied = false

    /// Set when a test notification could not be delivered, with what to do about it.
    private(set) var notificationNote: String?
    private(set) var notificationSettings = NotificationSettings()
    /// Whether Telltale opens at login. macOS records the app's location, so register it from where it will stay
    /// (see Scripts/install.sh).
    private(set) var launchAtLoginStatus: SMAppService.Status = SMAppService.mainApp.status
    private(set) var launchAtLoginError: String?

    let notifier: Notifier
    let history: HistoryModel
    private let engine: Engine
    private let store: Store
    private var consumer: Task<Void, Never>?
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    var menuState: MenuBarState {
        MenuBarState(diagnosis: latest?.diagnosis, interface: latest?.sample.interface, paused: paused)
    }

    var banner: Banner {
        PopoverContent.banner(diagnosis: latest?.diagnosis, now: latest?.sample.ts ?? Date())
    }

    var rows: [LayerRow] {
        PopoverContent.rows(samples: recent, diagnosis: latest?.diagnosis)
    }

    var chart: HTTPSChart { PopoverContent.httpsChart(samples: recent) }

    var connectionLine: String? { PopoverContent.connectionLine(recent.last) }

    init() {
        isDemo = ProcessInfo.processInfo.environment["TELLTALE_DEMO"] == "1"
        let store: Store
        let sampler: Sampler
        if isDemo {
            store = try! Store()
            sampler = DemoSampler.make()
        } else {
            let opened = Self.openStore()
            store = opened.store
            storageError = opened.error
            sampler = Sampler.live()
        }
        self.store = store
        notifier = Notifier()
        history = HistoryModel(store: store)
        let initialSettings = Self.loadNotificationSettings()
        notificationSettings = initialSettings
        engine = Engine(sampler: sampler, store: store, notificationSettings: initialSettings)
    }

    func start() {
        guard consumer == nil else { return }
        let updates = engine.updates
        consumer = Task { [weak self] in
            for await update in updates { self?.receive(update) }
        }
        // Refill the sparklines from the database, so a relaunch does not start with empty graphs.
        let store = store
        Task { [weak self] in
            let now = Date()
            let past = await Task.detached {
                (try? store.samples(from: now.addingTimeInterval(-1800), to: now)) ?? []
            }.value
            guard let self else { return }
            let firstLive = self.recent.first?.ts ?? .distantFuture
            self.recent = past.filter { $0.ts < firstLive } + self.recent
        }

        Task { await engine.start() }

        // Deliver what the NotificationPlanner decides, and open the History window when one is clicked.
        let notifications = engine.notifications
        Task { [weak self] in
            for await n in notifications {
                guard let self else { return }
                _ = await self.notifier.send(title: n.title, body: n.body, sound: n.sound,
                                             id: n.id, eventStart: n.eventStart)
            }
        }
        notifier.onOpenEvent = { [weak self] start in
            guard let self else { return }
            HistoryWindowController.shared.show(model: self)
            self.history.focus(onEventStartingAt: start)
        }

        // Stop measuring while the Mac sleeps, and start fresh on wake: samples taken while the network
        // is still reconnecting would otherwise read as an outage.
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.systemDidWake() }
        })
    }

    private func systemWillSleep() {
        sleeping = true
        Task { await engine.pause() }
    }

    private func systemDidWake() {
        sleeping = false
        if !paused { Task { await engine.start() } }
    }

    /// Puts a plain-text report (status, latest values, 10-minute stats, last 24 h of events) on the clipboard.
    func copyDiagnostics() {
        let now = Date()
        let events = (try? store.events(from: now.addingTimeInterval(-24 * 3600), to: now)) ?? []
        let text = DiagnosticsReport.make(samples: recent, diagnosis: latest?.diagnosis, events: events, now: now)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            justCopied = false
        }
    }

    func updateNotificationSettings(_ settings: NotificationSettings) {
        notificationSettings = settings
        let d = UserDefaults.standard
        d.set(settings.outageStart, forKey: "notify.outageStart")
        d.set(settings.outageSound, forKey: "notify.outageSound")
        d.set(settings.outageEnd, forKey: "notify.outageEnd")
        d.set(settings.qualityDrop, forKey: "notify.qualityDrop")
        Task { await engine.setNotificationSettings(settings) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    /// The user can also change this in System Settings, so re-read it when the Settings window opens.
    func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }

    private static func loadNotificationSettings() -> NotificationSettings {
        let d = UserDefaults.standard
        d.register(defaults: ["notify.outageStart": true, "notify.outageSound": true,
                              "notify.outageEnd": true, "notify.qualityDrop": true])
        var s = NotificationSettings()
        s.outageStart = d.bool(forKey: "notify.outageStart")
        s.outageSound = d.bool(forKey: "notify.outageSound")
        s.outageEnd = d.bool(forKey: "notify.outageEnd")
        s.qualityDrop = d.bool(forKey: "notify.qualityDrop")
        return s
    }

    func sendTestNotification() {
        Task {
            let sent = await notifier.send(title: "Telltale test", body: "Notifications are working.", sound: true)
            notificationNote = sent ? nil : "Notifications are off for Telltale. Turn them on in System Settings."
        }
    }

    private func receive(_ update: Engine.Update) {
        latest = update
        recent.append(update.sample)
        let cutoff = update.sample.ts.addingTimeInterval(-1800)
        if let firstKept = recent.firstIndex(where: { $0.ts >= cutoff }), firstKept > 0 {
            recent.removeFirst(firstKept)
        }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            Task { await engine.pause() }
        } else if !sleeping {
            Task { await engine.start() }
        }
    }

    private static func openStore() -> (store: Store, error: String?) {
        do {
            let dir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Telltale", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return (try Store(path: dir.appendingPathComponent("telltale.sqlite").path), nil)
        } catch {
            let message = "Couldn't open the history database. History won't be saved. (\(error.localizedDescription))"
            return (try! Store(), message)
        }
    }
}
