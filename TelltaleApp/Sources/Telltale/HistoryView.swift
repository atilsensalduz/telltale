import Charts
import SwiftUI
import TelltaleCore

/// The History window: range presets and layer toggles, a timeline with outage bands, summary tiles,
/// and the event table. Drag across the chart to zoom.
struct HistoryWindowView: View {
    let model: HistoryModel
    @State private var drag: DragSpan?
    @State private var selection: Event.ID?

    private struct DragSpan { var start: CGFloat; var end: CGFloat }

    private func color(_ kind: ProbeKind) -> Color {
        switch kind {
        case .gateway: return .teal
        case .cloudflare: return .purple
        case .google: return .pink
        case .dns: return .blue
        case .https: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let view = model.view {
                rangeLine(view)
                chart(view)
                summary(view.summary, longRange: view.range.duration > 86_400)
                eventsSection(view)
            } else if model.loadFailed {
                ContentUnavailableView("Couldn't read the history", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: 700, minHeight: 700)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: Binding(get: { model.preset }, set: { model.select($0) })) {
                ForEach(HistoryModel.Preset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            // On its own row so the layer names are never squeezed into "Rou…" and "1.1…".
            HStack(spacing: 6) {
                Text("Layers").font(.caption).foregroundStyle(.secondary)
                ForEach(ProbeKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { model.layers.contains(kind) }, set: { _ in model.toggle(kind) })) {
                        HStack(spacing: 4) {
                            Circle().fill(color(kind)).frame(width: 8, height: 8)
                            Text(kind.displayName).fixedSize()
                        }
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
            }
        }
    }

    private func rangeLine(_ v: HistoryView) -> some View {
        HStack {
            Text("\(v.range.start.formatted(date: .abbreviated, time: .shortened)) to "
                + "\(v.range.end.formatted(date: .abbreviated, time: .shortened)) "
                + "(\(History.shortDuration(v.range.duration)))")
            Spacer()
            Text("Drag across the chart to zoom")
            if model.zoom != nil {
                Button("Reset zoom") { model.resetZoom() }.controlSize(.small)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Chart

    private func chart(_ v: HistoryView) -> some View {
        Chart {
            ForEach(Array(v.gaps.enumerated()), id: \.offset) { _, gap in
                RectangleMark(xStart: .value("From", gap.start), xEnd: .value("To", gap.end),
                              yStart: .value("Min", 1.0), yEnd: .value("Max", 2000.0))
                    .foregroundStyle(.gray.opacity(0.15))
            }
            ForEach(v.events.filter { $0.kind != .pathChange }) { e in
                RectangleMark(xStart: .value("Start", bandStart(e, v)), xEnd: .value("End", bandEnd(e, v)),
                              yStart: .value("Min", 1.0), yEnd: .value("Max", 2000.0))
                    .foregroundStyle((e.kind == .outage ? Color.red : Color.orange).opacity(0.28))
            }
            ForEach(ProbeKind.allCases.filter { model.layers.contains($0) }, id: \.self) { kind in
                ForEach(Array(v.runs(for: kind).enumerated()), id: \.offset) { index, run in
                    ForEach(run, id: \.ts) { p in
                        LineMark(x: .value("Time", p.ts), y: .value("ms", max(p.value ?? 1, 1)),
                                 series: .value("Run", "\(kind.rawValue)-\(index)"))
                            .foregroundStyle(by: .value("Layer", kind.displayName))
                    }
                    if run.count == 1, let p = run.first {
                        PointMark(x: .value("Time", p.ts), y: .value("ms", max(p.value ?? 1, 1)))
                            .foregroundStyle(by: .value("Layer", kind.displayName))
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: ProbeKind.allCases.map(\.displayName),
                                   range: ProbeKind.allCases.map { color($0) })
        .chartYScale(domain: 1.0...2000.0, type: .log)
        .chartXScale(domain: v.range.start...v.range.end)
        .chartYAxis {
            AxisMarks(values: [1.0, 10.0, 100.0, 1000.0]) { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in dragOverlay(proxy) }
        .frame(height: 260)
        .accessibilityLabel("Latency timeline, logarithmic scale in milliseconds")
    }

    private func bandStart(_ e: Event, _ v: HistoryView) -> Date { max(e.start, v.range.start) }

    /// A very short event would be invisible on a long range, so bands get a minimum width.
    private func bandEnd(_ e: Event, _ v: HistoryView) -> Date {
        let end = min(e.end ?? model.now, v.range.end)
        return max(end, bandStart(e, v).addingTimeInterval(v.range.duration / 300))
    }

    private func dragOverlay(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            if let frame = proxy.plotFrame {
                let plot = geo[frame]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 6)
                                .onChanged { g in
                                    drag = DragSpan(start: clamp(g.startLocation.x, plot), end: clamp(g.location.x, plot))
                                }
                                .onEnded { g in
                                    let a = clamp(g.startLocation.x, plot), b = clamp(g.location.x, plot)
                                    drag = nil
                                    let left = proxy.value(atX: min(a, b) - plot.minX, as: Date.self)
                                    let right = proxy.value(atX: max(a, b) - plot.minX, as: Date.self)
                                    if let left, let right { model.zoom(to: DateInterval(start: left, end: right)) }
                                })
                    if let d = drag {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: abs(d.end - d.start), height: plot.height)
                            .offset(x: min(d.start, d.end), y: plot.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func clamp(_ x: CGFloat, _ plot: CGRect) -> CGFloat { min(plot.maxX, max(plot.minX, x)) }

    // MARK: - Summary

    private func summary(_ s: HistorySummary, longRange: Bool) -> some View {
        HStack(spacing: 8) {
            tile(s.uptime.map { String(format: longRange ? "%.2f%%" : "%.1f%%", $0 * 100) } ?? "n/a",
                 "Uptime while monitored")
            tile("\(s.outageCount)", "Outages")
            tile(s.downtime > 0 ? History.shortDuration(s.downtime) : "none", "Total downtime")
            tile(s.longestOutage > 0 ? History.shortDuration(s.longestOutage) : "none", "Longest outage")
            tile("\(Int((s.monitoredFraction * 100).rounded()))%", "Range monitored")
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.medium))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Events

    private func eventsSection(_ v: HistoryView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Outages only", isOn: Bindable(model).onlyOutages).toggleStyle(.checkbox)
                Spacer()
                if let note = model.exportNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button { model.export() } label: {
                    Label("Export CSV", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
            }
            if v.range.duration > 7 * 86_400 { dayList(v) } else { eventTable(v) }
        }
    }

    private func visible(_ v: HistoryView) -> [Event] {
        v.events.filter { !model.onlyOutages || $0.kind == .outage }
    }

    private var emptyMessage: some View {
        Text(model.onlyOutages ? "No outages in this range." : "No events in this range.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func eventTable(_ v: HistoryView) -> some View {
        let rows = Array(visible(v).reversed())
        return Group {
            if rows.isEmpty {
                emptyMessage
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("Start") { Text($0.start.formatted(date: .abbreviated, time: .standard)) }
                    TableColumn("Duration") { Text(duration($0)) }
                    TableColumn("Kind") { Text(kindName($0.kind)) }
                    TableColumn("Cause") { Text($0.cause?.rawValue ?? $0.detail ?? "") }
                }
                .onChange(of: selection) { _, id in
                    guard let id, let event = v.events.first(where: { $0.id == id }) else { return }
                    model.focus(on: event)
                    selection = nil
                }
            }
        }
        .frame(minHeight: 160)
    }

    private func dayList(_ v: HistoryView) -> some View {
        let groups = History.groupByDay(visible(v), now: model.now)
        return Group {
            if groups.isEmpty {
                emptyMessage
            } else {
                List(groups, id: \.day) { g in
                    Button { model.zoomToDay(g.day) } label: {
                        HStack {
                            Text(g.day.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(g.outageCount == 0
                                 ? "\(g.events.count) events"
                                 : "\(g.outageCount) outage\(g.outageCount == 1 ? "" : "s"), \(History.shortDuration(g.downtime)) down")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minHeight: 160)
    }

    private func duration(_ e: Event) -> String {
        guard e.kind != .pathChange else { return "" }
        let text = History.shortDuration((e.end ?? model.now).timeIntervalSince(e.start))
        return e.end == nil ? "\(text) (ongoing)" : text
    }

    private func kindName(_ kind: EventKind) -> String {
        switch kind {
        case .outage: return "Outage"
        case .degraded: return "Degraded"
        case .pathChange: return "Path change"
        }
    }
}
