//
//  UPnPDevice.swift
//
//  Copyright (c) 2023 Katoemba Software, (https://rigelian.net/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Created by Berrie Kremers on 08/01/2023.
//

import Foundation
import XMLCoder
import os.log

public struct UPnPDeviceDescription: Codable, Sendable {
    public let uuid: String
    public let deviceId: String
    public let deviceType: String
    public let url: URL
    public let server: String
    public let lastSeen: Date
    /// The DIAL `WAKEUP` header the device sent, if any.
    public let wakeUp: SSDPWakeUp?

    public init(uuid: String, deviceId: String, deviceType: String, url: URL, server: String = "", lastSeen: Date, wakeUp: SSDPWakeUp? = nil) {
        self.uuid = uuid
        self.deviceId = deviceId
        self.deviceType = deviceType
        self.url = url
        self.server = server
        self.lastSeen = lastSeen
        self.wakeUp = wakeUp
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, deviceId, deviceType, url, server, lastSeen, wakeUp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        deviceType = try container.decode(String.self, forKey: .deviceType)
        url = try container.decode(URL.self, forKey: .url)
        server = try container.decodeIfPresent(String.self, forKey: .server) ?? ""
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        wakeUp = try container.decodeIfPresent(SSDPWakeUp.self, forKey: .wakeUp)
    }
}

public class UPnPDevice: Equatable, Identifiable, Hashable {
    public let uuid: String
    public let deviceId: String
    public let deviceType: String
    public let url: URL
    public let server: String
    public var rootXML: String?
    public internal(set) var lastSeen: Date
    /// What the device's DIAL `WAKEUP` header said (DIAL 2.1 servers: many Android/Google TVs, Samsung, LG). Taken from
    /// whichever of its search responses carried it: often only the answer to the DIAL search target has it.
    public internal(set) var wakeUp: SSDPWakeUp?

    /// The MAC to send Wake-on-LAN to, normalized (`10:dd:b1:c9:00:e4`); nil if the device never sent `WAKEUP`.
    public var wakeOnLANMACAddress: String? {
        wakeUp?.macAddress
    }

    internal var upnpDeviceDescription: UPnPDeviceDescription {
        UPnPDeviceDescription(uuid: uuid, deviceId: deviceId, deviceType: deviceType, url: url, server: server, lastSeen: lastSeen, wakeUp: wakeUp)
    }
    
    public var data: Data? {
        try? JSONEncoder().encode(upnpDeviceDescription)
    }
    
    public var deviceDefinition: UPnPDeviceDefinition?
    @MainActor
    public var services = [UPnPService]()
    @MainActor
    public internal(set) var servicesLoaded: Bool {
        didSet {
            if servicesLoaded {
                lastSeen = Date()
            }
        }
    }
    
    internal init(uuid: String, deviceId: String, deviceType: String, url: URL, server: String = "", lastSeen: Date, wakeUp: SSDPWakeUp? = nil) {
        self.uuid = uuid
        self.deviceId = deviceId
        self.deviceType = deviceType
        self.url = url
        self.server = server
        self.lastSeen = lastSeen
        self.wakeUp = wakeUp
        self.servicesLoaded = false
    }
    
    public static func reanimate(from data: Data) -> UPnPDevice? {
        guard let upnpDeviceDescription = try? JSONDecoder().decode(UPnPDeviceDescription.self, from: data) else { return nil }
        return UPnPDevice(upnpDeviceDescription: upnpDeviceDescription)
    }
    
    @MainActor
    /// Create a fully loaded UPnPDevice, but without adding it to a device registry. There is no subscription for state changes on the services on this device, unless a valid UPnPRegistry is passed in.
    /// - Parameter data: a data representation of the description of the service
    /// - Parameter registry: a registry with a http server that can be used to receive events
    /// - Returns: a fully loaded device, or nil if it can't be found/loaded
    public static func reanimateDeep(from data: Data, registry: UPnPRegistry? = nil) async -> UPnPDevice? {
        guard let upnpDeviceDescription = try? JSONDecoder().decode(UPnPDeviceDescription.self, from: data) else { return nil }
        return await reanimateDeep(upnpDeviceDescription: upnpDeviceDescription, registry: registry)
    }

    @MainActor
    /// Create a fully loaded UPnPDevice, but without adding it to a device registry. There is no subscription for state changes on the services on this device, unless a valid UPnPRegistry is passed in.
    /// - Parameter upnpDeviceDescription: a description of the service
    /// - Parameter registry: a registry with a http server that can be used to receive events
    /// - Returns: a fully loaded device, or nil if it can't be found/loaded
    public static func reanimateDeep(upnpDeviceDescription: UPnPDeviceDescription, registry: UPnPRegistry? = nil) async -> UPnPDevice? {
        let device = UPnPDevice(upnpDeviceDescription: upnpDeviceDescription)
        
        if await device.loadServices(registry: registry) {
            device.servicesLoaded = true
            
            return device
        }
        
        return nil
    }
    
    internal init(upnpDeviceDescription: UPnPDeviceDescription) {
        self.uuid = upnpDeviceDescription.uuid
        self.deviceId = upnpDeviceDescription.deviceId
        self.deviceType = upnpDeviceDescription.deviceType
        self.url = upnpDeviceDescription.url
        self.server = upnpDeviceDescription.server
        self.lastSeen = upnpDeviceDescription.lastSeen
        self.wakeUp = upnpDeviceDescription.wakeUp
        self.servicesLoaded = false
    }

    public static func == (lhs: UPnPDevice, rhs: UPnPDevice) -> Bool {
        lhs.id == rhs.id
    }
    
    public var id: String {
        "\(uuid)::\(deviceId)"
    }

    /// `uuid` without its `uuid:` prefix: `roku:ecp:P0A070000007` for a Roku, the bare UUID for everything else.
    /// `uuid` itself keeps the prefix, as it always has, so identities that apps stored stay valid.
    public var bareUUID: String {
        uuid.lowercased().hasPrefix("uuid:") ? String(uuid.dropFirst(5)) : uuid
    }

    public func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
    }

    var description: String {
        "Device urn: \(id)\nurl: \(url)"
    }
    
    @MainActor
    func add(_ service: UPnPService) {
        services.append(service)
    }
    
    func loadServices(registry: UPnPRegistry?) async -> Bool {
        guard await loadRoot() == true else {
            Logger.swiftUPnP.error("Failed to load root on \(self.url)")
            return false
        }
            
        if let deviceServices = deviceDefinition?.device.serviceList?.service {
            for deviceService in deviceServices {
                // Create the service through the registry when there is one, so it is known there
                // and keeps receiving a valid event callback url.
                let service: UPnPService?
                if let registry {
                    service = await registry.typedService(device: self, serviceUrn: deviceService.serviceType)
                }
                else {
                    service = UPnPRegistry.typedService(device: self, serviceUrn: deviceService.serviceType)
                }
                guard let service else { continue }

                await service.loadScdp()
                await add(service)
            }
        }
        
        return true
    }
    
    typealias DescriptionTransport = (URLRequest) async throws -> (Data, URLResponse)

    /// TVs that just woke up, or are busy starting an app, take seconds to serve their description.
    static let descriptionTimeout: TimeInterval = 5
    static let descriptionRetryDelay: TimeInterval = 1

    /// Fetch the device description, with one retry after a timeout, a connection error, an empty answer or a
    /// server error. Other HTTP errors are final.
    static func fetchDescription(from url: URL,
                                 timeout: TimeInterval = descriptionTimeout,
                                 retryDelay: TimeInterval = descriptionRetryDelay,
                                 transport: DescriptionTransport = { try await URLSession.shared.data(for: $0) }) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpMethod = "GET"

        for attempt in 1...2 {
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
            }
            do {
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (200..<300).contains(status), !data.isEmpty {
                    return data
                }
                Logger.swiftUPnP.error("Device description from \(url.absoluteString) answered \(status) with \(data.count) bytes")
                guard status >= 500 || data.isEmpty else { return nil }
            }
            catch {
                Logger.swiftUPnP.error("Error: couldn't load device description from \(url.absoluteString): \(error.localizedDescription)")
            }
        }
        return nil
    }

    func loadRoot(transport: DescriptionTransport? = nil, retryDelay: TimeInterval = descriptionRetryDelay) async -> Bool {
        let data: Data?
        if let transport {
            data = await Self.fetchDescription(from: url, retryDelay: retryDelay, transport: transport)
        }
        else {
            data = await Self.fetchDescription(from: url, retryDelay: retryDelay)
        }
        guard let data else { return false }

        rootXML = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)

        do {
            let decoder = XMLDecoder()
            decoder.shouldProcessNamespaces = false
            deviceDefinition = try decoder.decode(UPnPDeviceDefinition.self, from: data)
            Logger.swiftUPnP.debug("Device parsed \(self.deviceDefinition!.device.friendlyName) - \(self.deviceDefinition!.device.deviceType  )")
            return true
        }
        catch DecodingError.dataCorrupted(let context) {
            Logger.swiftUPnP.error("\(context.debugDescription)")
        } catch DecodingError.keyNotFound(let key, let context) {
            Logger.swiftUPnP.error("\(key.stringValue) was not found, \(context.debugDescription)")
        } catch DecodingError.typeMismatch(let type, let context) {
            Logger.swiftUPnP.error("\(type) was expected, \(context.debugDescription)")
        } catch DecodingError.valueNotFound(let type, let context) {
            Logger.swiftUPnP.error("no value was found for \(type), \(context.debugDescription)")
        } catch {
            Logger.swiftUPnP.error("Unknown error \(error.localizedDescription)")
        }
        
        return false
    }    
}

@MainActor
extension UPnPDevice {
    public var connectionManager1Service: ConnectionManager1Service? {
        services.first(where: { $0.serviceType == "urn:schemas-upnp-org:service:ConnectionManager:1" }) as? ConnectionManager1Service
    }
    
    public var contentDirectory1Service: ContentDirectory1Service? {
        services.first(where: { $0.serviceType == "urn:schemas-upnp-org:service:ContentDirectory:1" }) as? ContentDirectory1Service
    }
    
    public var openHomeCredentials1Service: OpenHomeCredentials1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Credentials:1" }) as? OpenHomeCredentials1Service
    }
    
    public var openHomeInfo1Service: OpenHomeInfo1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Info:1" }) as? OpenHomeInfo1Service
    }
    
    public var openHomePins1Service: OpenHomePins1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Pins:1" }) as? OpenHomePins1Service
    }
    
    public var openHomePlaylist1Service: OpenHomePlaylist1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Playlist:1" }) as? OpenHomePlaylist1Service
    }
    
    public var openHomePlaylistManager1Service: OpenHomePlaylistManager1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:PlaylistManager:1" }) as? OpenHomePlaylistManager1Service
    }
    
    public var openHomeProduct1Service: OpenHomeProduct1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Product:1" }) as? OpenHomeProduct1Service
    }
    
    public var openHomeProduct2Service: OpenHomeProduct2Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Product:2" }) as? OpenHomeProduct2Service
    }
    
    public var openHomeRadio1Service: OpenHomeRadio1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Radio:1" }) as? OpenHomeRadio1Service
    }
    
    public var openHomeTime1Service: OpenHomeTime1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Time:1" }) as? OpenHomeTime1Service
    }
    
    public var openHomeTransport1Service: OpenHomeTransport1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Transport:1" }) as? OpenHomeTransport1Service
    }
    
    public var openHomeVolume1Service: OpenHomeVolume1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Volume:1" }) as? OpenHomeVolume1Service
    }
    
    public var openHomeVolume2Service: OpenHomeVolume2Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Volume:2" }) as? OpenHomeVolume2Service
    }
    
    public var openHomeSender1Service: OpenHomeSender1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Sender:1" }) as? OpenHomeSender1Service
    }
    
    public var openHomeReceiver1Service: OpenHomeReceiver1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:Receiver:1" }) as? OpenHomeReceiver1Service
    }
    
    public var openHomeOAuth1Service: OpenHomeOAuth1Service? {
        services.first(where: { $0.serviceType == "urn:av-openhome-org:service:OAuth:1" }) as? OpenHomeOAuth1Service
    }
}
