//
//  UPnPDeviceDescriptionLoadingTests.swift
//

import XCTest
import Combine
import Mocker
@testable import SwiftUPnP

/// What `GET http://<roku>:8060/` answers (trimmed): note the empty control and event URLs.
private let rokuDescription = """
<?xml version="1.0" encoding="UTF-8" ?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<specVersion><major>1</major><minor>0</minor></specVersion>
<device>
<deviceType>urn:roku-com:device:player:1-0</deviceType>
<friendlyName>Living Room Roku</friendlyName>
<manufacturer>Roku</manufacturer>
<manufacturerURL>http://www.roku.com/</manufacturerURL>
<modelDescription>Roku Streaming Player Network Media</modelDescription>
<modelName>Roku Ultra</modelName>
<modelNumber>4800X</modelNumber>
<modelURL>http://www.roku.com/</modelURL>
<serialNumber>P0A070000007</serialNumber>
<UDN>uuid:29600009-5406-1005-8080-1234567890ab</UDN>
<serviceList>
<service>
<serviceType>urn:roku-com:service:ecp:1</serviceType>
<serviceId>urn:roku-com:serviceId:ecp1-0</serviceId>
<controlURL/>
<eventSubURL/>
<SCPDURL>ecp_SCPD.xml</SCPDURL>
</service>
</serviceList>
</device>
</root>
"""

/// A TV with an incomplete description: no specVersion, no model name, and an icon without a depth.
private let sparseDescription = """
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
<device>
<deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
<friendlyName>[TV] Samsung 7 Series</friendlyName>
<manufacturer>Samsung Electronics</manufacturer>
<UDN>uuid:0ff0d8c0-0000-1000-8000-0123456789ab</UDN>
<iconList><icon><mimetype>image/png</mimetype><width>48</width><height>48</height><url>/icon.png</url></icon></iconList>
</device>
</root>
"""

/// Answers requests from a list, one per request, and counts them.
private final class ScriptedTransport {
    enum Answer {
        case status(Int, String)
        case failure(URLError.Code)
    }

    private var answers: [Answer]
    private(set) var requests = [URLRequest]()

    init(_ answers: [Answer]) {
        self.answers = answers
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        switch answers.isEmpty ? .failure(.cannotConnectToHost) : answers.removeFirst() {
        case let .status(code, body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!)
        case let .failure(code):
            throw URLError(code)
        }
    }
}

final class UPnPDeviceDescriptionLoadingTests: XCTestCase {
    private let rokuURL = URL(string: "http://192.168.1.134:8060/")!
    private var cancellables = Set<AnyCancellable>()

    override func tearDown() {
        cancellables.removeAll()
        Mocker.removeAll()
    }

    private func roku(_ id: String = "roku:ecp", url: URL? = nil) -> UPnPDevice {
        UPnPDevice(uuid: "uuid:roku:ecp:P0A070000007", deviceId: id, deviceType: id, url: url ?? rokuURL, lastSeen: Date())
    }

    // MARK: - Fetching

    func testASlowTVGetsOneRetry() async throws {
        let transport = ScriptedTransport([.failure(.timedOut), .status(200, rokuDescription)])

        let data = await UPnPDevice.fetchDescription(from: rokuURL, retryDelay: 0, transport: transport.send)

        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, rokuDescription)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.first?.timeoutInterval, 5)
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }

    func testOnlyOneRetry() async throws {
        let transport = ScriptedTransport([.failure(.timedOut), .failure(.timedOut), .status(200, rokuDescription)])

        let data = await UPnPDevice.fetchDescription(from: rokuURL, retryDelay: 0, transport: transport.send)

        XCTAssertNil(data)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testServerErrorsAndEmptyAnswersAreRetriedOtherErrorsAreNot() async throws {
        let busy = ScriptedTransport([.status(503, "busy"), .status(200, rokuDescription)])
        let busyData = await UPnPDevice.fetchDescription(from: rokuURL, retryDelay: 0, transport: busy.send)
        XCTAssertNotNil(busyData)

        let empty = ScriptedTransport([.status(200, ""), .status(200, rokuDescription)])
        let emptyData = await UPnPDevice.fetchDescription(from: rokuURL, retryDelay: 0, transport: empty.send)
        XCTAssertNotNil(emptyData)

        let missing = ScriptedTransport([.status(404, "not found"), .status(200, rokuDescription)])
        let missingData = await UPnPDevice.fetchDescription(from: rokuURL, retryDelay: 0, transport: missing.send)
        XCTAssertNil(missingData)
        XCTAssertEqual(missing.requests.count, 1)
    }

    func testLoadedRokuExposesItsIdentity() async throws {
        let device = roku()
        let transport = ScriptedTransport([.failure(.networkConnectionLost), .status(200, rokuDescription)])

        let loaded = await device.loadRoot(transport: transport.send, retryDelay: 0)

        XCTAssertTrue(loaded)
        XCTAssertEqual(device.uuid, "uuid:roku:ecp:P0A070000007")
        XCTAssertEqual(device.server, "")
        XCTAssertEqual(device.rootXML, rokuDescription)
        let definition = try XCTUnwrap(device.deviceDefinition)
        XCTAssertEqual(definition.device.manufacturer, "Roku")
        XCTAssertEqual(definition.device.modelName, "Roku Ultra")
        XCTAssertEqual(definition.device.friendlyName, "Living Room Roku")
        XCTAssertEqual(definition.device.UDN, "uuid:29600009-5406-1005-8080-1234567890ab")
        XCTAssertEqual(definition.device.serviceList?.service.first?.controlURL, "")
        XCTAssertEqual(definition.device.serviceList?.service.first?.SCPDURL, "ecp_SCPD.xml")
    }

    func testAnIncompleteDescriptionStillDescribesTheDevice() async throws {
        let device = UPnPDevice(uuid: "uuid:0ff0d8c0-0000-1000-8000-0123456789ab", deviceId: "urn:schemas-upnp-org:device:MediaRenderer:1",
                                deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1",
                                url: URL(string: "http://192.168.1.50:52235/dmr/SamsungMRDesc.xml")!, lastSeen: Date())

        let loaded = await device.loadRoot(transport: ScriptedTransport([.status(200, sparseDescription)]).send, retryDelay: 0)

        XCTAssertTrue(loaded)
        let definition = try XCTUnwrap(device.deviceDefinition)
        XCTAssertEqual(definition.device.manufacturer, "Samsung Electronics")
        XCTAssertEqual(definition.device.modelName, "")
        XCTAssertEqual(definition.specVersion.major, 1)
        XCTAssertNil(definition.device.iconList, "A broken icon list is left out, not fatal")
    }

    // MARK: - Registry

    private func registerRoku(onRequest: (() -> Void)? = nil) {
        var mock = Mock(url: rokuURL, contentType: .xml, statusCode: 200, data: [.get: Data(rokuDescription.utf8)])
        mock.completion = onRequest
        mock.register()
        // The service description isn't what these tests are about.
        Mock(url: URL(string: "http://192.168.1.134:8060/ecp_SCPD.xml")!, contentType: .xml, statusCode: 404, data: [.get: Data()]).register()
    }

    @MainActor
    func testEachDeviceAndLocationIsLoadedAndAnnouncedOnce() async throws {
        var requests = 0
        registerRoku { requests += 1 }
        let registry = UPnPRegistry()
        var announced = [UPnPDevice]()
        let added = expectation(description: "The Roku is announced")
        registry.deviceAdded.sink { device in
            announced.append(device)
            added.fulfill()
        }.store(in: &cancellables)

        // ssdp:all, upnp:rootdevice, roku:ecp and the repeated searches each bring their own answer.
        registry.add(roku("roku:ecp"))
        registry.add(roku("upnp:rootdevice"))
        registry.add(roku("roku:ecp"))
        registry.add(roku("uuid:roku:ecp:P0A070000007"))
        await fulfillment(of: [added], timeout: 5)

        // Answers that come in after loading don't load or announce it again either.
        registry.add(roku("upnp:rootdevice"))
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(announced.map(\.id), ["uuid:roku:ecp:P0A070000007::roku:ecp"])
        XCTAssertEqual(requests, 1)
    }

    @MainActor
    func testTheSameDeviceAtANewAddressIsLoadedAgain() async throws {
        registerRoku()
        let movedURL = URL(string: "http://192.168.1.135:8060/")!
        Mock(url: movedURL, contentType: .xml, statusCode: 200, data: [.get: Data(rokuDescription.utf8)]).register()
        Mock(url: URL(string: "http://192.168.1.135:8060/ecp_SCPD.xml")!, contentType: .xml, statusCode: 404, data: [.get: Data()]).register()
        let registry = UPnPRegistry()
        var announced = [URL]()
        let added = expectation(description: "Announced at both addresses")
        added.expectedFulfillmentCount = 2
        registry.deviceAdded.sink { device in
            announced.append(device.url)
            added.fulfill()
        }.store(in: &cancellables)

        registry.add(roku())
        try await Task.sleep(nanoseconds: 300_000_000)
        registry.add(roku(url: movedURL))
        await fulfillment(of: [added], timeout: 5)

        XCTAssertEqual(announced, [rokuURL, movedURL])
    }

    @MainActor
    func testAByebyeForTheRootDeviceRemovesItUnderAnyOfItsTypes() async throws {
        registerRoku()
        let registry = UPnPRegistry()
        let added = expectation(description: "added")
        registry.deviceAdded.sink { _ in added.fulfill() }.store(in: &cancellables)
        registry.add(roku("roku:ecp"))
        await fulfillment(of: [added], timeout: 5)

        let notRemoved = expectation(description: "A byebye for a single service keeps the device")
        notRemoved.isInverted = true
        var removal = registry.deviceRemoved.sink { _ in notRemoved.fulfill() }
        registry.remove(roku("urn:dial-multiscreen-org:service:dial:1"), wholeDevice: false)
        await fulfillment(of: [notRemoved], timeout: 0.3)
        removal.cancel()

        let removed = expectation(description: "removed")
        removal = registry.deviceRemoved.sink { device in
            XCTAssertEqual(device.uuid, "uuid:roku:ecp:P0A070000007")
            removed.fulfill()
        }
        registry.remove(roku("upnp:rootdevice"), wholeDevice: true)
        await fulfillment(of: [removed], timeout: 2)
        removal.cancel()
    }
}
