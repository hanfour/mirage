import Testing
@testable import MirageShell

@Suite struct HostAddressProbeTests {
    @Test func mergesFilteredInterfacesWithoutLosingNames() {
        let interfaces = [HostAddress(interface: "bridge100", ip: "192.168.139.3"),
                          HostAddress(interface: "utun8", ip: "100.119.248.33"),
                          HostAddress(interface: "en0", ip: "192.168.1.61"),
                          HostAddress(interface: "en1", ip: "192.168.1.61")]
        let result = HostAddressProbe.merged(interfaces: interfaces, defaultRoute: "192.168.1.61",
                                             tailscaleRoute: "100.119.248.33")
        #expect(result == [interfaces[2], interfaces[1], interfaces[0]])
        let filtered = HostAddressProbe.merged(interfaces: [interfaces[0]], defaultRoute: "192.168.1.61",
                                               tailscaleRoute: "100.119.248.33")
        #expect(filtered == [interfaces[0], .init(interface: "route", ip: "192.168.1.61"),
                             .init(interface: "route", ip: "100.119.248.33")])
    }

    @Test func injectedProbeUsesBothDestinationsWithoutNetwork() {
        var destinations: [String] = []
        let result = HostAddressProbe.current(interfaces: []) { destination in
            destinations.append(destination)
            return destination == "1.1.1.1" ? "192.168.1.61" : "100.119.248.33"
        }
        #expect(destinations == ["1.1.1.1", "100.100.100.100"])
        #expect(result.map(\.ip) == ["192.168.1.61", "100.119.248.33"])
    }

    @Test func absentRoutesKeepInterfacesAndNonTailscaleFallbackIsIgnored() {
        let interfaces = [HostAddress(interface: "bridge100", ip: "192.168.139.3")]
        #expect(HostAddressProbe.current(interfaces: interfaces, probe: { _ in nil }) == interfaces)
        #expect(HostAddressProbe.merged(interfaces: [], defaultRoute: nil,
                                        tailscaleRoute: "192.168.1.61").isEmpty)
        #expect(HostAddressProbe.merged(interfaces: [], defaultRoute: "100.64.0.1",
                                        tailscaleRoute: "100.64.0.1").count == 1)
    }

    @Test(arguments: ["0.0.0.0", "127.0.0.1", "255.255.255.255", "broken", "192.168.1.999"])
    func invalidDefaultRouteIsIgnored(_ ip: String) {
        #expect(HostAddressProbe.merged(interfaces: [], defaultRoute: ip, tailscaleRoute: nil).isEmpty)
    }

    @Test(arguments: ["10.0.0.0", "192.168.139.3", "172.16.0.0", "172.31.255.255",
                       "100.64.0.0", "100.127.255.255"])
    func localRangesSuppressHint(_ ip: String) {
        #expect(!HostAddressProbe.needsLocalNetworkHint(["1.1.1.1", ip]))
    }

    @Test(arguments: ["172.15.255.255", "172.32.0.0", "100.63.255.255", "100.128.0.0",
                       "192.169.0.1", "127.0.0.1", "10.999.0.1", "10.1.1", "::1"])
    func otherRangesNeedHint(_ ip: String) {
        #expect(HostAddressProbe.needsLocalNetworkHint([ip]))
    }

    @Test func emptyAndPublicMenusShowDisabledHintEntry() {
        #expect(HostAddressProbe.needsLocalNetworkHint([]))
        #expect(RemoteMenu.entries(.on(urls: ["http://1.1.1.1:8765/"], session: .initial))
            .contains(.status(RemoteMenu.localNetworkHint)))
    }
}
