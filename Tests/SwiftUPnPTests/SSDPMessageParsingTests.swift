//
//  SSDPMessageParsingTests.swift
//
//  Packets as TVs send them, including their quirks.
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

final class SSDPMessageParsingTests: XCTestCase {
    private func crlf(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private func discovery(types: [String] = UPnPRegistry.tvSearchTargets) -> RecordingDiscovery {
        let discovery = RecordingDiscovery()
        discovery.types = types
        return discovery
    }

    private func onlyDevice(_ discovery: RecordingDiscovery, file: StaticString = #filePath, line: UInt = #line) throws -> (SSDPMessageType, UPnPDevice) {
        XCTAssertEqual(discovery.messages.count, 1, file: file, line: line)
        let (type, device) = try XCTUnwrap(discovery.messages.first, file: file, line: line)
        return (type, try XCTUnwrap(device, file: file, line: line))
    }

    // MARK: - Real packets

    private let rokuResponse = ["HTTP/1.1 200 OK",
                                "Cache-Control: max-age=3600",
                                "ST: roku:ecp",
                                "Location: http://192.168.1.134:8060/",
                                "USN: uuid:roku:ecp:P0A070000007"]

    func testRokuResponseWithoutDoubleColonInTheUSNIsAccepted() throws {
        let discovery = discovery()
        discovery.processData(crlf(rokuResponse))

        let (type, device) = try onlyDevice(discovery)
        XCTAssertEqual(type, .searchResponse)
        XCTAssertEqual(device.uuid, "uuid:roku:ecp:P0A070000007")
        XCTAssertEqual(device.bareUUID, "roku:ecp:P0A070000007")
        XCTAssertEqual(device.deviceId, "roku:ecp")
        XCTAssertEqual(device.deviceType, "roku:ecp")
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.134:8060/"))
        // Roku sends no SERVER header.
        XCTAssertEqual(device.server, "")
    }

    func testSamsungMediaRendererResponse() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "CACHE-CONTROL: max-age=1800",
                                    "DATE: Fri, 31 Oct 2026 10:00:00 GMT",
                                    "EXT:",
                                    "LOCATION: http://192.168.1.21:9197/dmr",
                                    "SERVER: SHP, UPnP/1.0, Samsung UPnP SDK/1.0",
                                    "ST: urn:schemas-upnp-org:device:MediaRenderer:1",
                                    "USN: uuid:5b2a3c4d-0000-1000-8000-a0d0b1c2d3e4::urn:schemas-upnp-org:device:MediaRenderer:1",
                                    "Content-Length: 0",
                                    "BOOTID.UPNP.ORG: 2"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.uuid, "uuid:5b2a3c4d-0000-1000-8000-a0d0b1c2d3e4")
        XCTAssertEqual(device.bareUUID, "5b2a3c4d-0000-1000-8000-a0d0b1c2d3e4")
        XCTAssertEqual(device.deviceId, "urn:schemas-upnp-org:device:MediaRenderer:1")
        XCTAssertEqual(device.id, "uuid:5b2a3c4d-0000-1000-8000-a0d0b1c2d3e4::urn:schemas-upnp-org:device:MediaRenderer:1")
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.21:9197/dmr"))
        XCTAssertEqual(device.server, "SHP, UPnP/1.0, Samsung UPnP SDK/1.0")
    }

    func testLGWebOSResponseWithVendorHeaders() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "CACHE-CONTROL: max-age=1800",
                                    "DATE: Fri, 31 Oct 2026 10:00:00 GMT",
                                    "EXT:",
                                    "LOCATION: http://192.168.1.30:1086/",
                                    "SERVER: WebOS/4.1.0 UPnP/1.0",
                                    "ST: urn:lge-com:service:webos-second-screen:1",
                                    "USN: uuid:a7d1e3b2-6f8e-4c2a-9a64-1c2d3e4f5a6b::urn:lge-com:service:webos-second-screen:1",
                                    "DLNADeviceName.lge.com: %5bLG%5d%20webOS%20TV%20OLED55C1"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.uuid, "uuid:a7d1e3b2-6f8e-4c2a-9a64-1c2d3e4f5a6b")
        XCTAssertEqual(device.deviceType, "urn:lge-com:service:webos-second-screen:1")
        XCTAssertEqual(device.server, "WebOS/4.1.0 UPnP/1.0")
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.30:1086/"))
    }

    func testDIALResponseFromAnAndroidTV() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "CACHE-CONTROL: max-age=1800",
                                    "DATE: Fri, 31 Oct 2026 10:00:00 GMT",
                                    "EXT:",
                                    "LOCATION: http://192.168.1.40:8008/ssdp/device-desc.xml",
                                    "OPT: \"http://schemas.upnp.org/upnp/1/0/\"; ns=01",
                                    "01-NLS: 161803398874989",
                                    "SERVER: Linux/3.8.13+, UPnP/1.0, Portable SDK for UPnP devices/1.6.18",
                                    "X-User-Agent: redsonic",
                                    "ST: urn:dial-multiscreen-org:service:dial:1",
                                    "USN: uuid:3e1cc7c3-f4f1-4e5b-8cfe-e6a5a0e4d000::urn:dial-multiscreen-org:service:dial:1",
                                    "BOOTID.UPNP.ORG: 7",
                                    "CONFIGID.UPNP.ORG: 7"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.deviceType, "urn:dial-multiscreen-org:service:dial:1")
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.40:8008/ssdp/device-desc.xml"))
        XCTAssertEqual(device.server, "Linux/3.8.13+, UPnP/1.0, Portable SDK for UPnP devices/1.6.18")
    }

    func testRokuByebyeIsAboutTheDeviceThatLeaves() throws {
        let discovery = discovery()
        discovery.processData(crlf(["NOTIFY * HTTP/1.1",
                                    "HOST: 239.255.255.250:1900",
                                    "NT: roku:ecp",
                                    "NTS: ssdp:byebye",
                                    "USN: uuid:roku:ecp:P0A070000007"]))

        let (type, device) = try onlyDevice(discovery)
        XCTAssertEqual(type, .unavailableNotification)
        XCTAssertEqual(device.id, "uuid:roku:ecp:P0A070000007::roku:ecp")
        XCTAssertFalse(SSDPDiscovery.isWholeDeviceTarget(device.deviceId))
    }

    func testRootDeviceByebyeTakesTheWholeDevice() throws {
        let discovery = discovery()
        discovery.processData(crlf(["NOTIFY * HTTP/1.1",
                                    "HOST: 239.255.255.250:1900",
                                    "NT: upnp:rootdevice",
                                    "NTS: ssdp:byebye",
                                    "USN: uuid:5b2a3c4d-0000-1000-8000-a0d0b1c2d3e4::upnp:rootdevice"]))

        let (type, device) = try onlyDevice(discovery)
        XCTAssertEqual(type, .unavailableNotification)
        XCTAssertTrue(SSDPDiscovery.isWholeDeviceTarget(device.deviceId))
        XCTAssertTrue(SSDPDiscovery.isWholeDeviceTarget("uuid:5b2a3c4d-0000-1000-8000-a0d0b1c2d3e4"))
    }

    func testAliveAnnouncementOfARoku() throws {
        let discovery = discovery()
        discovery.processData(crlf(["NOTIFY * HTTP/1.1",
                                    "HOST: 239.255.255.250:1900",
                                    "Cache-Control: max-age=3600",
                                    "NT: roku:ecp",
                                    "NTS: ssdp:alive",
                                    "Location: http://192.168.1.134:8060/",
                                    "USN: uuid:roku:ecp:P0A070000007"]))

        let (type, device) = try onlyDevice(discovery)
        XCTAssertEqual(type, .availableNotification)
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.134:8060/"))
    }

    // MARK: - Leniency

    func testLFOnlyLineEndings() throws {
        let discovery = discovery()
        discovery.processData(Data((rokuResponse.joined(separator: "\n") + "\n\n").utf8))

        XCTAssertEqual(try onlyDevice(discovery).1.uuid, "uuid:roku:ecp:P0A070000007")
    }

    func testLowercaseHeadersWithoutSpaceAfterTheColon() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "st:roku:ecp",
                                    "location:http://192.168.1.134:8060/",
                                    "usn:uuid:roku:ecp:P0A070000007"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.134:8060/"))
        XCTAssertEqual(device.deviceType, "roku:ecp")
    }

    func testMixedCaseHeadersAndPaddedValues() throws {
        let discovery = discovery()
        discovery.processData(crlf(["  HTTP/1.1 200 OK  ",
                                    "Location :   http://192.168.1.21:9197/dmr   ",
                                    "sT:\turn:schemas-upnp-org:device:MediaRenderer:1",
                                    "Usn: uuid:abc::urn:schemas-upnp-org:device:MediaRenderer:1 ",
                                    "Server:Linux"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.21:9197/dmr"))
        XCTAssertEqual(device.deviceType, "urn:schemas-upnp-org:device:MediaRenderer:1")
        XCTAssertEqual(device.uuid, "uuid:abc")
        XCTAssertEqual(device.server, "Linux")
    }

    func testMissingCacheControlExtAndServer() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "LOCATION: http://192.168.1.50:52235/dmr/SamsungMRDesc.xml",
                                    "ST: urn:schemas-upnp-org:device:tvdevice:1",
                                    "USN: uuid:0ff0d8c0-0000-1000-8000-0123456789ab::urn:schemas-upnp-org:device:tvdevice:1"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.server, "")
        XCTAssertEqual(device.deviceType, "urn:schemas-upnp-org:device:tvdevice:1")
    }

    func testDuplicateHeadersKeepTheFirstValue() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "LOCATION:",
                                    "LOCATION: http://192.168.1.134:8060/",
                                    "LOCATION: http://192.168.1.99:8060/",
                                    "ST: roku:ecp",
                                    "USN: uuid:roku:ecp:P0A070000007",
                                    "USN: uuid:roku:ecp:SOMETHINGELSE"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.url, URL(string: "http://192.168.1.134:8060/"))
        XCTAssertEqual(device.uuid, "uuid:roku:ecp:P0A070000007")
    }

    func testResponseWithoutReasonPhraseOrWithHTTP10() throws {
        for startLine in ["HTTP/1.1 200", "HTTP/1.0 200 OK", "http/1.1 200 ok"] {
            let discovery = discovery()
            discovery.processData(crlf([startLine] + rokuResponse.dropFirst()))
            XCTAssertEqual(discovery.messages.first?.0, .searchResponse, startLine)
        }
    }

    func testUnknownStartLineIsJudgedByItsHeaders() throws {
        let response = discovery()
        response.processData(crlf(["SSDP/1.0 RESPONSE"] + rokuResponse.dropFirst()))
        XCTAssertEqual(try onlyDevice(response).0, .searchResponse)

        let notification = discovery()
        notification.processData(crlf(["NOTIFY HTTP/1.1",
                                       "NT: roku:ecp",
                                       "NTS: ssdp:alive",
                                       "Location: http://192.168.1.134:8060/",
                                       "USN: uuid:roku:ecp:P0A070000007"]))
        XCTAssertEqual(try onlyDevice(notification).0, .availableNotification)
    }

    func testLeadingEmptyLinesAndABodyAreIgnored() throws {
        let discovery = discovery()
        discovery.processData(Data(("\r\n" + rokuResponse.joined(separator: "\r\n") + "\r\n\r\nUSN: uuid:other\r\n").utf8))

        XCTAssertEqual(try onlyDevice(discovery).1.uuid, "uuid:roku:ecp:P0A070000007")
    }

    func testLatin1ServerHeaderDoesNotDropThePacket() throws {
        let data = try XCTUnwrap((rokuResponse.joined(separator: "\r\n") + "\r\nSERVER: T\u{e9}l\u{e9}viseur\r\n\r\n").data(using: .isoLatin1))
        let discovery = discovery()
        discovery.processData(data)

        XCTAssertEqual(try onlyDevice(discovery).1.server, "T\u{e9}l\u{e9}viseur")
    }

    func testMessagesWithoutADeviceAreIgnored() {
        let discovery = discovery()
        // Another control point's search, which the announcement socket also hears.
        discovery.processData(crlf(["M-SEARCH * HTTP/1.1",
                                    "HOST: 239.255.255.250:1900",
                                    "MAN: \"ssdp:discover\"",
                                    "ST: ssdp:all",
                                    "MX: 3"]))
        discovery.processData(crlf(["HTTP/1.1 404 Not Found", "USN: uuid:x", "LOCATION: http://192.168.1.2/"]))
        discovery.processData(Data())
        discovery.processData(Data("\r\n\r\n".utf8))
        discovery.processData(Data("garbage".utf8))
        // A response without a USN or a location can't become a device.
        discovery.processData(crlf(["HTTP/1.1 200 OK", "ST: roku:ecp", "LOCATION: http://192.168.1.134:8060/"]))
        discovery.processData(crlf(["HTTP/1.1 200 OK", "ST: roku:ecp", "USN: uuid:roku:ecp:P0A070000007"]))
        discovery.processData(crlf(["HTTP/1.1 200 OK", "ST: roku:ecp", "LOCATION: http://192.168.1.134:8060/", "USN: ::roku:ecp"]))

        XCTAssertTrue(discovery.messages.allSatisfy { $0.1 == nil })
        XCTAssertEqual(discovery.messages.count, 3)
    }

    func testStartLineWithoutHeaders() {
        XCTAssertEqual(SSDPMessage("NOTIFY * HTTP/1.1")?.kind, .notification)
        XCTAssertEqual(SSDPMessage("NOTIFY * HTTP/1.1")?.headers, [:])
        XCTAssertNil(SSDPMessage(""))
    }

    // MARK: - Announcements

    func testAnnouncementsOfOtherTypesAreIgnored() {
        let discovery = discovery(types: ["roku:ecp"])
        discovery.processData(crlf(["NOTIFY * HTTP/1.1",
                                    "NT: urn:schemas-upnp-org:device:ZonePlayer:1",
                                    "NTS: ssdp:alive",
                                    "LOCATION: http://192.168.1.60:1400/xml/device_description.xml",
                                    "USN: uuid:RINCON_000E58000000001400::urn:schemas-upnp-org:device:ZonePlayer:1"]))

        XCTAssertTrue(discovery.messages.isEmpty)
    }

    func testAnnouncementsOfAnyTypeAreTakenWhenSearchingForAll() throws {
        let discovery = discovery(types: ["ssdp:all"])
        discovery.processData(crlf(["NOTIFY * HTTP/1.1",
                                    "NT: urn:schemas-upnp-org:device:ZonePlayer:1",
                                    "NTS: ssdp:alive",
                                    "LOCATION: http://192.168.1.60:1400/xml/device_description.xml",
                                    "USN: uuid:RINCON_000E58000000001400::urn:schemas-upnp-org:device:ZonePlayer:1"]))

        XCTAssertEqual(try onlyDevice(discovery).0, .availableNotification)
    }

    func testByebyeOfAnyTypeIsPassedOn() throws {
        let discovery = discovery(types: ["roku:ecp"])
        discovery.processData(crlf(["NOTIFY * HTTP/1.1",
                                    "NT: upnp:rootdevice",
                                    "NTS: SSDP:BYEBYE",
                                    "USN: uuid:roku:ecp:P0A070000007::upnp:rootdevice"]))

        XCTAssertEqual(try onlyDevice(discovery).0, .unavailableNotification)
    }

    // MARK: - USN

    func testUniqueServiceNames() throws {
        let roku = try XCTUnwrap(SSDPUniqueServiceName("uuid:roku:ecp:P0A070000007"))
        XCTAssertEqual(roku.device, "uuid:roku:ecp:P0A070000007")
        XCTAssertEqual(roku.uuid, "roku:ecp:P0A070000007")
        XCTAssertNil(roku.type)

        let service = try XCTUnwrap(SSDPUniqueServiceName(" UUID:ABC::urn:dial-multiscreen-org:service:dial:1 "))
        XCTAssertEqual(service.device, "UUID:ABC")
        XCTAssertEqual(service.uuid, "ABC")
        XCTAssertEqual(service.type, "urn:dial-multiscreen-org:service:dial:1")

        let bare = try XCTUnwrap(SSDPUniqueServiceName("uuid:abc::"))
        XCTAssertEqual(bare.uuid, "abc")
        XCTAssertNil(bare.type)

        XCTAssertNil(SSDPUniqueServiceName(""))
        XCTAssertNil(SSDPUniqueServiceName("::upnp:rootdevice"))
    }

    // MARK: - DIAL WAKEUP

    func testDIALResponseWithWakeUpCarriesTheMAC() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "CACHE-CONTROL: max-age=1800",
                                    "EXT:",
                                    "LOCATION: http://192.168.1.40:8008/ssdp/device-desc.xml",
                                    "SERVER: Linux/4.9, UPnP/1.0, Portable SDK for UPnP devices/1.6.25",
                                    "ST: urn:dial-multiscreen-org:service:dial:1",
                                    "USN: uuid:3e1cc7c3-f4f1-4e5b-8cfe-e6a5a0e4d000::urn:dial-multiscreen-org:service:dial:1",
                                    "WAKEUP: MAC=10:dd:b1:c9:00:e4;Timeout=10"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.wakeOnLANMACAddress, "10:dd:b1:c9:00:e4")
        XCTAssertEqual(device.wakeUp?.timeout, 10)
    }

    func testResponseWithoutWakeUpHasNoMAC() throws {
        let discovery = discovery()
        discovery.processData(crlf(rokuResponse))

        XCTAssertNil(try onlyDevice(discovery).1.wakeOnLANMACAddress)
    }

    func testWakeUpHeaderIsReadInAnyCase() throws {
        let discovery = discovery()
        discovery.processData(crlf(["HTTP/1.1 200 OK",
                                    "location: http://192.168.1.41:8008/ssdp/device-desc.xml",
                                    "st: urn:dial-multiscreen-org:service:dial:1",
                                    "usn: uuid:abc::urn:dial-multiscreen-org:service:dial:1",
                                    "wakeup: mac=10-DD-B1-C9-00-E4; timeout=15"]))

        let (_, device) = try onlyDevice(discovery)
        XCTAssertEqual(device.wakeOnLANMACAddress, "10:dd:b1:c9:00:e4")
        XCTAssertEqual(device.wakeUp?.timeout, 15)
    }

    func testWakeUpParsingIsLenient() {
        XCTAssertEqual(SSDPWakeUp("MAC=10:dd:b1:c9:00:e4;Timeout=10"), SSDPWakeUp(macAddress: "10:dd:b1:c9:00:e4", timeout: 10))
        // Order, spacing, separators, quotes and the MAC's spelling vary between vendors.
        XCTAssertEqual(SSDPWakeUp(" Timeout = 30 , MAC = \"10DDB1C900E4\" ")?.macAddress, "10:dd:b1:c9:00:e4")
        XCTAssertEqual(SSDPWakeUp(" Timeout = 30 , MAC = \"10DDB1C900E4\" ")?.timeout, 30)
        XCTAssertEqual(SSDPWakeUp("mac=10dd.b1c9.00e4")?.macAddress, "10:dd:b1:c9:00:e4")
        XCTAssertEqual(SSDPWakeUp("MAC=10:DD:B1:C9:00:E4;")?.macAddress, "10:dd:b1:c9:00:e4")
        XCTAssertEqual(SSDPWakeUp("MAC=10:dd:b1:c9:00:e4;Timeout=soon")?.timeout, nil)
        XCTAssertEqual(SSDPWakeUp("MAC=10:dd:b1:c9:00:e4;Vendor=x;Timeout=5")?.timeout, 5)
        // Only the MAC, without its name.
        XCTAssertEqual(SSDPWakeUp("10:dd:b1:c9:00:e4")?.macAddress, "10:dd:b1:c9:00:e4")
    }

    func testWakeUpWithoutAUsableMACIsIgnored() {
        XCTAssertNil(SSDPWakeUp(nil))
        XCTAssertNil(SSDPWakeUp(""))
        XCTAssertNil(SSDPWakeUp("Timeout=10"))
        XCTAssertNil(SSDPWakeUp("MAC=;Timeout=10"))
        XCTAssertNil(SSDPWakeUp("MAC=10:dd:b1:c9:00"))
        XCTAssertNil(SSDPWakeUp("MAC=10:dd:b1:c9:00:e4:ff"))
        XCTAssertNil(SSDPWakeUp("MAC=zz:dd:b1:c9:00:e4"))
        XCTAssertNil(SSDPWakeUp("MAC=00:00:00:00:00:00"))
        XCTAssertNil(SSDPWakeUp("MAC=ff:ff:ff:ff:ff:ff"))
    }

    func testWakeUpSurvivesTheStoredDescription() throws {
        let device = UPnPDevice(uuid: "uuid:abc", deviceId: "upnp:rootdevice", deviceType: "upnp:rootdevice",
                                url: try XCTUnwrap(URL(string: "http://192.168.1.40:8008/")), lastSeen: Date(),
                                wakeUp: SSDPWakeUp(macAddress: "10:dd:b1:c9:00:e4", timeout: 10))
        let restored = try XCTUnwrap(UPnPDevice.reanimate(from: try XCTUnwrap(device.data)))
        XCTAssertEqual(restored.wakeOnLANMACAddress, "10:dd:b1:c9:00:e4")

        // Descriptions stored before the header was read still load.
        let old = Data(#"{"uuid":"uuid:abc","deviceId":"upnp:rootdevice","deviceType":"upnp:rootdevice","url":"http://192.168.1.40:8008/","lastSeen":0}"#.utf8)
        let restoredOld = try XCTUnwrap(UPnPDevice.reanimate(from: old))
        XCTAssertNil(restoredOld.wakeOnLANMACAddress)
    }
}
