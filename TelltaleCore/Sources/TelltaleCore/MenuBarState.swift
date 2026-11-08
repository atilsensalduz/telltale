import Foundation

/// Which glyph the menu bar shows. Each level has its own shape as well as its own colour,
/// so the state is readable without colour vision and survives monochrome rendering.
public enum GlyphLevel: Equatable, Sendable {
    /// No data yet, or paused. Hollow circle.
    case idle
    /// Filled circle.
    case healthy
    /// Triangle.
    case degraded
    /// Square.
    case outage
}

extension ProbeKind {
    /// Name of the layer as shown to the user.
    public var displayName: String {
        switch self {
        case .gateway: return "Router"
        case .cloudflare: return "1.1.1.1"
        case .google: return "8.8.8.8"
        case .dns: return "DNS"
        case .https: return "HTTPS"
        }
    }
}

/// What the menu bar item shows: a glyph, plus a short cause next to it only when something is wrong.
public struct MenuBarState: Equatable, Sendable {
    public var level: GlyphLevel
    /// nil when healthy or still starting: a healthy network takes no menu bar space beyond the glyph.
    public var label: String?

    public init(level: GlyphLevel, label: String?) {
        self.level = level; self.label = label
    }

    public init(diagnosis: Diagnosis?, interface: InterfaceKind? = nil, paused: Bool = false) {
        if paused {
            self.init(level: .idle, label: "Paused")
            return
        }
        guard let diagnosis else {
            self.init(level: .idle, label: nil)
            return
        }
        switch diagnosis.status {
        case .healthy:
            self.init(level: .healthy, label: nil)
        case .degraded(let reasons):
            self.init(level: .degraded, label: Self.degradedLabel(reasons))
        case .outage(let cause):
            self.init(level: .outage, label: Self.shortName(cause, interface: interface))
        }
    }

    /// Short cause names for the menu bar. The router is Wi-Fi when Wi-Fi carries the route.
    public static func shortName(_ cause: Cause, interface: InterfaceKind?) -> String {
        switch cause {
        case .localNetwork: return interface == .wifi ? "Wi-Fi" : "Router"
        case .isp: return "ISP"
        case .dns: return "DNS"
        case .webPath: return "Web"
        }
    }

    /// Names the layer closest to the user when several are affected, e.g. "HTTPS slow", "Router loss".
    static func degradedLabel(_ reasons: [DegradeReason]) -> String? {
        func kind(_ r: DegradeReason) -> ProbeKind {
            switch r { case .loss(let k), .highLatency(let k): return k }
        }
        let order = ProbeKind.allCases
        guard let first = reasons.min(by: {
            (order.firstIndex(of: kind($0)) ?? 0) < (order.firstIndex(of: kind($1)) ?? 0)
        }) else { return nil }
        switch first {
        case .loss(let k): return "\(k.displayName) loss"
        case .highLatency(let k): return "\(k.displayName) slow"
        }
    }
}
