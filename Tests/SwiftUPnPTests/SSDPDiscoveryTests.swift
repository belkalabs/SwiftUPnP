//
//  SSDPDiscoveryTests.swift
//

import XCTest
@testable import SwiftUPnP

/// Records which devices the received messages are about, instead of handing them to the registry.
private final class RecordingDiscovery: SSDPDiscovery {
    var messages: [(SSDPMessageType, UPnPDevice?)] = []

    override func handleSSDPMessage(_ messageType: SSDPMessageType, headers: [String: String]) {
        messages.append((messageType, device(from: headers)))
    }
}

final class SSDPDiscoveryTests: XCTestCase {
    private let sourceType = "urn:av-openhome-org:device:Source:1"
    private let usn = "uuid:4c494e4e-0026-0f21-cc2c-01303402013f::urn:av-openhome-org:device:Source:1"

    private func message(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    func testAByebyeIsAboutTheDeviceThatLeaves() throws {
        let discovery = RecordingDiscovery()
        discovery.types = [sourceType]

        discovery.processData(message(["NOTIFY * HTTP/1.1",
                                       "HOST: 239.255.255.250:1900",
                                       "NT: \(sourceType)",
                                       "NTS: ssdp:byebye",
                                       "USN: \(usn)"]))

        let (type, device) = try XCTUnwrap(discovery.messages.first)
        XCTAssertEqual(type, .unavailableNotification)
        // The device is removed by its id; a byebye has no location, which must not make it unreadable.
        XCTAssertEqual(device?.id, "uuid:4c494e4e-0026-0f21-cc2c-01303402013f::urn:av-openhome-org:device:Source:1")
    }

    func testAnAliveIsAboutTheDeviceAtItsLocation() throws {
        let discovery = RecordingDiscovery()
        discovery.types = [sourceType]

        discovery.processData(message(["NOTIFY * HTTP/1.1",
                                       "HOST: 239.255.255.250:1900",
                                       "LOCATION: http://192.168.1.20:55178/Ds/device.xml",
                                       "NT: \(sourceType)",
                                       "NTS: ssdp:alive",
                                       "USN: \(usn)"]))

        let (type, device) = try XCTUnwrap(discovery.messages.first)
        XCTAssertEqual(type, .availableNotification)
        XCTAssertEqual(device?.url, URL(string: "http://192.168.1.20:55178/Ds/device.xml"))
    }

    func testMessagesAboutOtherTypesAreIgnoredWhenFilteringIsEnabled() throws {
        let discovery = RecordingDiscovery()
        discovery.requiredDefaultFiltration = true
        discovery.types = ["urn:schemas-upnp-org:device:MediaServer:1"]

        discovery.processData(message(["NOTIFY * HTTP/1.1",
                                       "HOST: 239.255.255.250:1900",
                                       "NT: \(sourceType)",
                                       "NTS: ssdp:byebye",
                                       "USN: \(usn)"]))

        XCTAssertNil(try XCTUnwrap(discovery.messages.first).1)
    }

    func testTVServiceResponsesAreAcceptedWithoutDefaultFiltering() throws {
        let discovery = RecordingDiscovery()
        discovery.types = [sourceType]
        let tvTypes = ["urn:dial-multiscreen-org:service:dial:1",
                       "urn:panasonic-com:service:p00NetworkControl:1",
                       "roku:ecp"]

        for type in tvTypes {
            discovery.processData(message(["HTTP/1.1 200 OK",
                                           "LOCATION: http://192.168.1.20/device.xml",
                                           "SERVER: Linux/5.4 UPnP/1.0 TV",
                                           "ST: \(type)",
                                           "USN: uuid:tv::\(type)"]))
        }

        let devices = try discovery.messages.map { try XCTUnwrap($0.1) }
        XCTAssertEqual(devices.map(\.deviceType), tvTypes)
        XCTAssertTrue(devices.allSatisfy { $0.server == "Linux/5.4 UPnP/1.0 TV" })
    }

    func testSearchRequestPreservesTVCompatibleHeaders() throws {
        let discovery = SSDPDiscovery()
        let data = try XCTUnwrap(discovery.searchRequestData(forType: "roku:ecp"))
        let request = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(request.contains("ST: roku:ecp\r\n"))
        XCTAssertTrue(request.contains("MX: 5\r\n"))
        XCTAssertTrue(request.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(request.contains("USER-AGENT:"))
    }
}
