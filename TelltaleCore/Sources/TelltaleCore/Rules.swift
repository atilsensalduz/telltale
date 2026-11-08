import Foundation

/// Stateless, per-sample diagnosis rules. A direct port of `diagnose()` in netwatch.py.
/// First match wins. Only `.fail` counts as failure; `.unavailable` is never a failure.
public enum Rules {
    /// - Parameter skipGateway: true when the router is known not to answer ICMP; rule 1 is skipped.
    /// - Returns: the cause, or nil when no rule matches (healthy as far as this sample shows).
    public static func classify(_ s: Sample, skipGateway: Bool = false) -> Cause? {
        if !skipGateway && s.gateway.isFail { return .localNetwork }
        if s.cloudflare.isFail && s.google.isFail { return .isp }
        if s.dns.isFail { return .dns }
        if s.https.isFail { return .webPath }
        return nil
    }
}
