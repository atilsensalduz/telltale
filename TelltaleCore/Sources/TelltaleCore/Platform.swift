import Foundation
import CoreWLAN
import SystemConfiguration

/// Source of the default route at the start of each tick.
public protocol NetworkEnvironment: Sendable {
    func snapshot() -> ProbeEnvironment
}

/// Source of Wi-Fi link stats (read-only, no Location permission needed; no SSID).
public protocol WifiSource: Sendable {
    func read() -> WifiStats?
}

public enum InterfaceClassifier {
    /// Interface name prefixes used by VPN and tunnel clients.
    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    /// - Parameters:
    ///   - bsdName: e.g. "en0", "utun3".
    ///   - scType: SystemConfiguration interface type string ("IEEE80211", "Ethernet", ...), if known.
    ///   - wifiName: BSD name of the Wi-Fi interface according to CoreWLAN, if any.
    public static func kind(bsdName: String, scType: String?, wifiName: String?) -> InterfaceKind {
        if tunnelPrefixes.contains(where: bsdName.hasPrefix) { return .vpn }
        if bsdName == wifiName || scType == "IEEE80211" { return .wifi }
        if scType == "Ethernet" { return .ethernet }
        return .other
    }
}

/// Reads the IPv4 default route from SystemConfiguration. When there is no default route
/// (link down), it keeps reporting the last known interface so a Wi-Fi drop is not mistaken
/// for a path change, which would reset the Diagnoser's windows.
public final class SystemNetworkEnvironment: NetworkEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var lastInterface: InterfaceKind = .other

    public init() {}

    public func snapshot() -> ProbeEnvironment {
        var gateway: String?
        var primary: String?
        if let store = SCDynamicStoreCreate(nil, "telltale" as CFString, nil, nil),
           let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            gateway = dict["Router"] as? String
            primary = dict["PrimaryInterface"] as? String
        }
        lock.lock(); defer { lock.unlock() }
        if let primary {
            lastInterface = InterfaceClassifier.kind(
                bsdName: primary, scType: Self.scType(for: primary),
                wifiName: CWWiFiClient.shared().interface()?.interfaceName)
        }
        return ProbeEnvironment(gateway: gateway, interface: lastInterface)
    }

    static func scType(for bsdName: String) -> String? {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for i in all where SCNetworkInterfaceGetBSDName(i) as String? == bsdName {
            return SCNetworkInterfaceGetInterfaceType(i) as String?
        }
        return nil
    }
}

public struct CoreWLANSource: WifiSource {
    public init() {}

    public func read() -> WifiStats? {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return nil }
        let rssi = i.rssiValue()
        guard rssi != 0 else { return nil }   // 0 means "not associated"
        return WifiStats(rssi: rssi, noise: i.noiseMeasurement(),
                         channel: i.wlanChannel()?.channelNumber ?? 0,
                         txRateMbps: i.transmitRate())
    }
}
