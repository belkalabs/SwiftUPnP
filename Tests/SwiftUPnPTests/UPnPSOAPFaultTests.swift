import XCTest
import Mocker
@testable import SwiftUPnP

final class UPnPSOAPFaultTests: XCTestCase {
    private struct Envelope: Codable {
        var body = "test"
    }

    private struct Response: Decodable {
        let value: String
    }

    private let url = URL(string: "http://192.0.2.10/control")!
    private var device: UPnPDevice!
    private var service: UPnPService!

    override func setUpWithError() throws {
        device = UPnPDevice(uuid: "uuid:soap-test", deviceId: "tv",
                            deviceType: "urn:test:device:TV:1", url: url, lastSeen: Date())
        service = UPnPService(device: device, controlUrl: url, scpdUrl: url, eventUrl: nil,
                              serviceType: "urn:schemas-upnp-org:service:AVTransport:1",
                              serviceId: "urn:upnp-org:serviceId:AVTransport")
    }

    override func tearDownWithError() throws {
        service = nil
        device = nil
        Mocker.removeAll()
    }

    func testActionWithoutOutputReportsTheUPnPError() async throws {
        register(status: 500, body: "<UPnPError><errorCode>402</errorCode><errorDescription>Invalid Args</errorDescription></UPnPError>")

        do {
            try await service.post(action: "Play", envelope: Envelope())
            XCTFail("A refused action must not succeed")
        } catch ServiceParseError.soapFault(let action, let code, let description) {
            XCTAssertEqual(action, "Play")
            XCTAssertEqual(code, "402")
            XCTAssertEqual(description, "Invalid Args")
        }
    }

    func testActionWithOutputReportsNamespacedFaultBeforeDecoding() async throws {
        register(status: 500, body: "<s:Fault xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" xmlns:u=\"urn:schemas-upnp-org:control-1-0\"><u:errorCode>701</u:errorCode><u:errorDescription>Transition not available</u:errorDescription></s:Fault>")

        do {
            let _: Response = try await service.postWithResult(action: "GetTransportInfo", envelope: Envelope())
            XCTFail("A fault must be reported before decoding the response")
        } catch ServiceParseError.soapFault(let action, let code, let description) {
            XCTAssertEqual(action, "GetTransportInfo")
            XCTAssertEqual(code, "701")
            XCTAssertEqual(description, "Transition not available")
        }
    }

    func testNonXMLFailureReportsHTTPStatus() async throws {
        register(status: 503, body: "Service unavailable")

        do {
            try await service.post(action: "Play", envelope: Envelope())
            XCTFail("An HTTP error must not succeed")
        } catch ServiceParseError.soapFault(_, let code, let description) {
            XCTAssertEqual(code, "503")
            XCTAssertEqual(description, "no description")
        }
    }

    func testSuccessfulActionWithoutResponseBodyIsAccepted() async throws {
        register(status: 204, body: "")
        try await service.post(action: "Play", envelope: Envelope())
    }

    private func register(status: Int, body: String) {
        Mock(url: url, contentType: .xml, statusCode: status, data: [.post: Data(body.utf8)]).register()
    }
}
