import AppKit
import TelltaleCore

/// Draws the menu bar glyph as a non-template image, so its colour is kept instead of being
/// flattened to monochrome. Shape also encodes the state: hollow circle (idle), filled circle
/// (healthy), triangle (degraded), square (outage).
enum StatusGlyph {
    static func image(for level: GlyphLevel) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let r = rect.insetBy(dx: 2, dy: 2)
            switch level {
            case .idle:
                NSColor.secondaryLabelColor.setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
                p.lineWidth = 1.5
                p.stroke()
            case .healthy:
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: r).fill()
            case .degraded:
                NSColor.systemOrange.setFill()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: r.midX, y: r.maxY))
                p.line(to: NSPoint(x: r.maxX, y: r.minY))
                p.line(to: NSPoint(x: r.minX, y: r.minY))
                p.close()
                p.fill()
            case .outage:
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func accessibilityName(_ level: GlyphLevel) -> String {
        switch level {
        case .idle: return "Telltale, idle"
        case .healthy: return "Telltale, network healthy"
        case .degraded: return "Telltale, network quality dropped"
        case .outage: return "Telltale, network outage"
        }
    }
}
