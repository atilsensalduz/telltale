import Foundation
import Testing
@testable import TelltaleCore

private func diag(_ status: Status) -> Diagnosis {
    Diagnosis(status: status, since: nil, gatewayIcmpBlocked: false)
}

@Test func noDataYetIsIdleWithoutLabel() {
    #expect(MenuBarState(diagnosis: nil) == MenuBarState(level: .idle, label: nil))
}

@Test func pausedIsIdleAndSaysSoEvenWithData() {
    let s = MenuBarState(diagnosis: diag(.outage(.isp)), paused: true)
    #expect(s == MenuBarState(level: .idle, label: "Paused"))
}

@Test func healthyHasGlyphAndNoLabel() {
    #expect(MenuBarState(diagnosis: diag(.healthy)) == MenuBarState(level: .healthy, label: nil))
}

@Test func outageLabelsAreShortCauseNames() {
    func label(_ c: Cause, _ i: InterfaceKind? = nil) -> String? {
        MenuBarState(diagnosis: diag(.outage(c)), interface: i).label
    }
    #expect(label(.isp) == "ISP")
    #expect(label(.dns) == "DNS")
    #expect(label(.webPath) == "Web")
    #expect(MenuBarState(diagnosis: diag(.outage(.dns))).level == .outage)
}

@Test func localNetworkNamesWifiOnlyWhenWifiIsTheRoute() {
    #expect(MenuBarState(diagnosis: diag(.outage(.localNetwork)), interface: .wifi).label == "Wi-Fi")
    #expect(MenuBarState(diagnosis: diag(.outage(.localNetwork)), interface: .ethernet).label == "Router")
    #expect(MenuBarState(diagnosis: diag(.outage(.localNetwork)), interface: nil).label == "Router")
}

@Test func degradedLabelsNameTheLayerAndTheSymptom() {
    func state(_ r: [DegradeReason]) -> MenuBarState { MenuBarState(diagnosis: diag(.degraded(r))) }
    #expect(state([.highLatency(.https)]) == MenuBarState(level: .degraded, label: "HTTPS slow"))
    #expect(state([.loss(.cloudflare)]).label == "1.1.1.1 loss")
}

@Test func degradedWithSeveralReasonsNamesTheLayerClosestToTheUser() {
    let s = MenuBarState(diagnosis: diag(.degraded([.loss(.dns), .highLatency(.https), .loss(.gateway)])))
    #expect(s.label == "Router loss")
}

@Test func degradedWithNoReasonsHasNoLabel() {
    #expect(MenuBarState(diagnosis: diag(.degraded([]))) == MenuBarState(level: .degraded, label: nil))
}

@Test func layerDisplayNames() {
    #expect(ProbeKind.allCases.map(\.displayName) == ["Router", "1.1.1.1", "8.8.8.8", "DNS", "HTTPS"])
}
