//
//  SSDPReliabilityTests.swift
//

import XCTest
import Combine
import Mocker
import Network
@testable import SwiftUPnP

final class SSDPReliabilityTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        Mocker.removeAll()
    }

    // MARK: - Stop while starting

    @MainActor
    func testAStopWhileTheHTTPServerStartsIsNotUndoneByTheStart() async throws {
        let registry = UPnPRegistry(httpServerPortRange: 52100..<52199)

        registry.startContinuousDiscovery(["ssdp:all"])
        registry.stopDiscovery()
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertFalse(registry.isDiscoveryRunning, "Continuous discovery must not survive a stop issued while it was starting")
    }

    @MainActor
    func testTheLastStartWins() async throws {
        let registry = UPnPRegistry(httpServerPortRange: 52200..<52299)

        registry.startContinuousDiscovery(["ssdp:all"])
        registry.stopDiscovery()
        registry.startContinuousDiscovery(["ssdp:all"])
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(registry.isDiscoveryRunning)
        registry.stopDiscovery()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(registry.isDiscoveryRunning)
    }

    // MARK: - Failed descriptions

    @MainActor
    func testAFailedDescriptionIsNotFetchedAgainForAMinute() async throws {
        let url = URL(string: "http://192.168.1.77:49152/description.xml")!
        var requests = 0
        var mock = Mock(url: url, contentType: .xml, statusCode: 404, data: [.get: Data("not found".utf8)])
        mock.completion = { requests += 1 }
        mock.register()

        let registry = UPnPRegistry(httpServerPortRange: 52300..<52399)
        var clock = Date()
        registry.now = { clock }
        let device = { UPnPDevice(uuid: "uuid:sleepy", deviceId: "upnp:rootdevice", deviceType: "upnp:rootdevice", url: url, lastSeen: Date()) }

        registry.add(device())
        try await waitUntil { requests == 1 }
        try await Task.sleep(nanoseconds: 300_000_000)

        // Continuous discovery brings the same answer every few seconds.
        registry.add(device())
        registry.add(device())
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(requests, 1)

        clock = clock.addingTimeInterval(UPnPRegistry.failedDescriptionRetryInterval + 1)
        registry.add(device())
        try await waitUntil { requests == 2 }
        XCTAssertEqual(requests, 2)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Network changes

    func testOnlyLocalInterfacesAndTheirAddressesCount() {
        let addresses = ["en0": "192.168.1.5", "pdp_ip0": "10.20.30.40", "bridge100": "172.20.10.1"]
        let address: (String) -> String? = { addresses[$0] }

        let wifi = SSDPLocalNetworkSignature.make(interfaces: [(name: "en0", type: .wifi)], address: address)
        let wifiAndCellular = SSDPLocalNetworkSignature.make(interfaces: [(name: "en0", type: .wifi), (name: "pdp_ip0", type: .cellular)], address: address)
        XCTAssertEqual(wifi, wifiAndCellular, "Cellular coming or going doesn't reopen the sockets")
        XCTAssertFalse(wifi.isEmpty)

        let otherAddress = SSDPLocalNetworkSignature.make(interfaces: [(name: "en0", type: .wifi)]) { _ in "192.168.7.9" }
        XCTAssertNotEqual(wifi, otherAddress, "Another Wi-Fi (a new address) reopens them")

        let cellularOnly = SSDPLocalNetworkSignature.make(interfaces: [(name: "pdp_ip0", type: .cellular)], address: address)
        XCTAssertTrue(cellularOnly.isEmpty)

        let hotspot = SSDPLocalNetworkSignature.make(interfaces: [(name: "bridge100", type: .other), (name: "pdp_ip0", type: .cellular)], address: address)
        XCTAssertEqual(hotspot.interfaces, ["bridge100=172.20.10.1"])
        let bridgeWithoutAddress = SSDPLocalNetworkSignature.make(interfaces: [(name: "bridge0", type: .other)], address: address)
        XCTAssertTrue(bridgeWithoutAddress.isEmpty)
        let vpn = SSDPLocalNetworkSignature.make(interfaces: [(name: "utun3", type: .other)]) { _ in "10.8.0.2" }
        XCTAssertTrue(vpn.isEmpty)
    }

    func testBackoffDoublesUpToTheMaximumAndStartsOverAfterAReset() {
        var backoff = SSDPBackoff(initial: 2, maximum: 60)
        XCTAssertEqual((0..<7).map { _ in backoff.nextDelay() }, [2, 4, 8, 16, 32, 60, 60])
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 2)
    }
}
