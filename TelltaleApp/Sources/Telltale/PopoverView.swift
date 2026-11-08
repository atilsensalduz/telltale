import Charts
import SwiftUI
import TelltaleCore

/// Banner, one row per layer, connection line, 10-minute HTTPS chart, then Pause and Quit.
/// The history and diagnostics buttons come in a later milestone.
struct PopoverView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BannerView(banner: model.banner)

            let rows = model.rows
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    LayerRowView(row: row)
                    if row.id != rows.last?.id { Divider().opacity(0.5) }
                }
            }

            if let line = model.connectionLine {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            HTTPSChartView(chart: model.chart)

            if model.isDemo {
                Text("Demo mode: scripted network").font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.storageError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let note = model.notificationNote {
                Text(note).font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("Open history") { HistoryWindowController.shared.show(model: model) }
                Button(model.paused ? "Resume" : "Pause") { model.setPaused(!model.paused) }
                Button(model.justCopied ? "Copied" : "Copy diagnostics") { model.copyDiagnostics() }
            }
            .controlSize(.small)
            HStack {
                Button("Settings…") { SettingsWindowController.shared.show(model: model) }
                Spacer()
                Button("Quit Telltale") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }
}

// MARK: - Banner

private struct BannerView: View {
    let banner: Banner

    private var tint: Color {
        switch banner.style {
        case .neutral: return .gray
        case .healthy: return .green
        case .degraded: return .orange
        case .outage: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.title).font(.headline)
            Text(banner.subtitle).font(.caption).foregroundStyle(.secondary)
            if let note = banner.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Layer row

private struct LayerRowView: View {
    let row: LayerRow

    private var valueColor: Color {
        switch row.health {
        case .ok: return .primary
        case .slow: return .orange
        case .failing: return .red
        case .unavailable: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.kind.displayName)
                .font(.system(size: 12))
                .frame(width: 60, alignment: .leading)
            Text(row.valueText)
                .font(.system(size: 12, weight: row.health == .ok ? .regular : .medium).monospacedDigit())
                .foregroundStyle(valueColor)
                .frame(width: 52, alignment: .trailing)
            Sparkline(points: row.points, tint: row.health == .slow ? .orange : .secondary)
                .frame(height: 20)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.kind.displayName), \(row.valueText)")
    }
}

// MARK: - HTTPS chart

/// What a browser experiences, over the last 10 minutes. Failed requests are red marks and break the line.
private struct HTTPSChartView: View {
    let chart: HTTPSChart

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 30 minutes, HTTPS").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(chart.points) { p in
                    LineMark(x: .value("Time", p.ts), y: .value("ms", p.ms),
                             series: .value("Segment", p.segment))
                        .foregroundStyle(.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                }
                ForEach(chart.failures, id: \.self) { t in
                    RuleMark(x: .value("Failed", t))
                        .foregroundStyle(.red.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
            .chartXScale(domain: chart.start...chart.end)
            .chartYScale(domain: .automatic(includesZero: true))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = value.as(Double.self) { Text("\(Int(ms))") }
                    }
                }
            }
            .frame(height: 70)
            .accessibilityLabel("HTTPS latency over the last 30 minutes")
        }
    }
}

// MARK: - Sparkline

/// Latency line per bucket. A failed bucket is a red tick; a gap breaks the line.
private struct Sparkline: View {
    let points: [SparkPoint]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }
            let peak = max(points.compactMap { if case .value(let v) = $0 { v } else { nil } }.max() ?? 1, 1)
            let step = size.width / CGFloat(points.count - 1)
            func y(_ v: Double) -> CGFloat { size.height - 2 - CGFloat(v / peak) * (size.height - 4) }

            var run: [CGPoint] = []
            func flush() {
                defer { run.removeAll() }
                if run.count == 1, let p = run.first {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)), with: .color(tint))
                } else if run.count > 1 {
                    var path = Path()
                    path.move(to: run[0])
                    run.dropFirst().forEach { path.addLine(to: $0) }
                    context.stroke(path, with: .color(tint), lineWidth: 1.2)
                }
            }

            for (i, point) in points.enumerated() {
                let x = CGFloat(i) * step
                switch point {
                case .value(let v):
                    run.append(CGPoint(x: x, y: y(v)))
                case .failure:
                    flush()
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: 2))
                    tick.addLine(to: CGPoint(x: x, y: size.height - 2))
                    context.stroke(tick, with: .color(.red), lineWidth: 1.5)
                case .gap:
                    flush()
                }
            }
            flush()
        }
    }
}
