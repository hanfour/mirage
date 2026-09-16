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

    @Test(arguments: ["bridge100", "vmnet1", "vmenet0", "lo0", "route0"])
    func virtualInterfacesCannotSuppressHint(_ interface: String) {
        #expect(HostAddressProbe.needsLocalNetworkHint([.init(interface: interface, ip: "192.168.139.3")]))
    }

    @Test(arguments: ["en0", "en1", "utun8", "route"], ["192.168.139.3", "1.1.1.1"])
    func usableSourcesSuppressHintRegardlessOfSubnet(_ interface: String, _ ip: String) {
        #expect(!HostAddressProbe.needsLocalNetworkHint([.init(interface: interface, ip: ip)]))
    }

    @Test func onlyBridgeNeedsHint() {
        #expect(HostAddressProbe.needsLocalNetworkHint([.init(interface: "bridge100", ip: "192.168.139.3")]))
    }

    @Test func bridgeAndEthernetSuppressHint() {
        #expect(!HostAddressProbe.needsLocalNetworkHint([
            .init(interface: "bridge100", ip: "192.168.139.3"), .init(interface: "en0", ip: "192.168.1.61"),
        ]))
    }

    @Test func onlyRouteSuppressesHint() {
        #expect(!HostAddressProbe.needsLocalNetworkHint([.init(interface: "route", ip: "192.168.1.61")]))
    }

    @Test func emptyListNeedsHint() {
        #expect(HostAddressProbe.needsLocalNetworkHint([]))
    }
}
