import AppKit
import Foundation
import Observation
import TelltaleCore

/// State behind the History window: the selected range and zoom, which layers are drawn, and the loaded data.
/// Loading happens off the main thread; while the window is open the view refreshes every few seconds.
@MainActor
@Observable
final class HistoryModel {
    enum Preset: CaseIterable, Identifiable {
        case tenMinutes, hour, sixHours, day, twoDays, week, quarter

        var id: Self { self }

        var title: String {
            switch self {
            case .tenMinutes: return "10 min"
            case .hour: return "1 h"
            case .sixHours: return "6 h"
            case .day: return "24 h"
            case .twoDays: return "48 h"
            case .week: return "7 d"
            case .quarter: return "90 d"
            }
        }

        var seconds: TimeInterval {
            switch self {
            case .tenMinutes: return 600
            case .hour: return 3600
            case .sixHours: return 6 * 3600
            case .day: return 24 * 3600
            case .twoDays: return 48 * 3600
            case .week: return 7 * 86_400
            case .quarter: return 90 * 86_400
            }
        }
    }

    private(set) var view: HistoryView?
    private(set) var loadFailed = false
    private(set) var exportNote: String?
    /// The instant the current range was computed against.
    private(set) var now = Date()
    private(set) var preset: Preset = .hour
    /// A zoomed-in range chosen by dragging on the chart or selecting an event; nil follows the preset.
    private(set) var zoom: DateInterval?
    private(set) var layers: Set<ProbeKind> = [.https]
    var onlyOutages = false

    private let store: Store
    private var refreshTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    init(store: Store) {
        self.store = store
    }

    var range: DateInterval {
        zoom ?? DateInterval(start: now.addingTimeInterval(-preset.seconds), end: now)
    }

    // MARK: - Intents

    func select(_ preset: Preset) {
        self.preset = preset
        zoom = nil
        refresh()
    }

    func zoom(to range: DateInterval) {
        guard range.duration >= 5 else { return }
        zoom = range
        refresh()
    }

    func resetZoom() {
        zoom = nil
        refresh()
    }

    /// Zooms to an event with some padding, so what led up to it and what followed are visible.
    func focus(on event: Event) {
        let end = event.end ?? Date()
        let pad = max(end.timeIntervalSince(event.start) * 0.6, 60)
        zoom(to: DateInterval(start: event.start.addingTimeInterval(-pad), end: end.addingTimeInterval(pad)))
    }

    /// Zooms to the event that began at `start` (a clicked notification carries only that time), or to a
    /// window around it if the event is no longer in the database.
    func focus(onEventStartingAt start: Date) {
        let store = store
        Task {
            let found = await Task.detached {
                try? store.events(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1))
            }.value ?? []
            if let event = found.first(where: { $0.kind != .pathChange && abs($0.start.timeIntervalSince(start)) < 1 }) {
                focus(on: event)
            } else {
                zoom(to: DateInterval(start: start.addingTimeInterval(-300), end: start.addingTimeInterval(300)))
            }
        }
    }

    func zoomToDay(_ day: Date) {
        zoom(to: DateInterval(start: day, duration: 86_400))
    }

    func toggle(_ kind: ProbeKind) {
        if layers.contains(kind) {
            if layers.count > 1 { layers.remove(kind) }       // keep at least one line on the chart
        } else {
            layers.insert(kind)
        }
    }

    /// Called when the window opens and closes. Refreshing only while it is open keeps the idle cost at zero.
    func setActive(_ active: Bool) {
        liveTask?.cancel()
        liveTask = nil
        guard active else { return }
        refresh()
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                if self.zoom == nil { self.refresh() }
            }
        }
    }

    // MARK: - Loading

    func refresh() {
        refreshTask?.cancel()
        let now = Date()
        self.now = now
        let range = zoom ?? DateInterval(start: now.addingTimeInterval(-preset.seconds), end: now)
        let store = store
        refreshTask = Task {
            let loaded = await Task.detached { try? History.view(store: store, range: range, now: now) }.value
            guard !Task.isCancelled else { return }
            view = loaded
            loadFailed = loaded == nil
        }
    }

    // MARK: - Export

    /// Writes the samples and events of the current range as two CSV files into a folder the user picks.
    /// Raw samples are kept for 48 hours, so the samples file never reaches further back than that.
    func export() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose a folder for the samples and events CSV files."
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let range = self.range
        let now = Date()
        let store = store
        Task {
            do {
                let (samplesCSV, eventsCSV, sampleCount, eventCount, truncated) = try await Task.detached {
                    let rawStart = max(range.start, now.addingTimeInterval(-48 * 3600))
                    let samples = rawStart < range.end ? try store.samples(from: rawStart, to: range.end) : []
                    let events = try store.events(from: range.start, to: range.end)
                    return (CSVExport.samples(samples), CSVExport.events(events, now: now),
                            samples.count, events.count, rawStart > range.start)
                }.value

                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyyMMdd-HHmm"
                let stamp = formatter.string(from: now)
                try samplesCSV.write(to: folder.appendingPathComponent("telltale-samples-\(stamp).csv"),
                                     atomically: true, encoding: .utf8)
                try eventsCSV.write(to: folder.appendingPathComponent("telltale-events-\(stamp).csv"),
                                    atomically: true, encoding: .utf8)
                exportNote = "Saved \(sampleCount) samples and \(eventCount) events."
                    + (truncated ? " Samples older than 48 hours exist only as 1-minute summaries, so they are not included." : "")
            } catch {
                exportNote = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }
}
