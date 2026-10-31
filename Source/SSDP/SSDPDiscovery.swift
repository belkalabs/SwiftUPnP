//
//  SSDPDiscoveryProtocol.swift
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
//  Created by Berrie Kremers on 03/03/2022.
//


import Foundation
import os.log

public enum UPnPError: Error {
    case alreadyConnected
    case networkingError(String)
}

enum SSDPMessageType: String {
    case searchResponse
    case availableNotification
    case updateNotification
    case unavailableNotification
}

class SSDPDiscovery: NSObject {
    let multicastGroupAddress = "239.255.255.250"
    let multicastUDPPort: UInt16 = 1900
    var types = [String]()
    var requiredDefaultFiltration = false

    func searchRequestData(forType type: String) -> Data? {
        ["M-SEARCH * HTTP/1.1",
         "MAN: \"ssdp:discover\"",
         "HOST: \(multicastGroupAddress):\(multicastUDPPort)",
         "ST: \(type)",
         "MX: 5",
         "\r\n"].joined(separator: "\r\n").data(using: .utf8)
    }

    func handleSSDPMessage(_ messageType: SSDPMessageType, headers: [String: String]) {
        guard let device = device(from: headers) else { return }
        if messageType == .unavailableNotification {
            // A byebye for the root device, or for the device itself, means all of it leaves. One for a single
            // service or embedded device only takes that registration away.
            let wholeDevice = Self.isWholeDeviceTarget(device.deviceId)
            Task {
                await UPnPRegistry.shared.remove(device, wholeDevice: wholeDevice)
            }
        }
        else {
            Task {
                await UPnPRegistry.shared.add(device)
            }
        }
    }

    static func isWholeDeviceTarget(_ type: String) -> Bool {
        let type = type.lowercased()
        return type == "upnp:rootdevice" || type.hasPrefix("uuid:")
    }

    /// Strict response filtering is optional because TVs also advertise vendor-specific services.
    func device(from headers: [String: String]) -> UPnPDevice? {
        guard let usnRawValue = headers["usn"],
              let usn = SSDPUniqueServiceName(usnRawValue),
              let locationString = headers["location"],
              let locationURL = URL(string: locationString.trimmingCharacters(in: .whitespacesAndNewlines)),
              /// NT = Notification Type - SSDP discovered from device advertisements
              /// ST = Search Target - SSDP discovered as a result of using M-SEARCH requests
              let ssdpType = Self.nonEmpty(headers["st"]) ?? Self.nonEmpty(headers["nt"]) ?? usn.type,
              (!requiredDefaultFiltration || types.contains(ssdpType)) else { return nil }

        // A USN without a type (Roku's `uuid:roku:ecp:<serial>`, or a device's own `uuid:<id>`) is told apart
        // by the target it answered or announced.
        return UPnPDevice(uuid: usn.device, deviceId: usn.type ?? ssdpType, deviceType: ssdpType, url: locationURL, server: headers["server"] ?? "", lastSeen: Date())
    }

    /// Announcements arrive for every device on the network, not just the searched ones: only take those that
    /// would also have answered one of the searches.
    func acceptsAnnouncement(ofType type: String?) -> Bool {
        guard !types.isEmpty, !types.contains("ssdp:all") else { return true }
        guard let type else { return false }
        return types.contains(type)
    }

    func processData(_ data: Data) {
        guard let message = SSDPMessage(data: data) else { return }
        var headers = message.headers

        switch message.kind {
        case .searchResponse:
            handleSSDPMessage(.searchResponse, headers: headers)
        case .notification:
            switch message.notificationSubtype {
            case "ssdp:byebye":
                // Byebye messages don't have a location, and a device is removed by its id only. The host
                // header (the multicast address) is only a stand-in, and needs a scheme to make a valid URL.
                if Self.nonEmpty(headers["location"]) == nil {
                    headers["location"] = "http://\(Self.nonEmpty(headers["host"]) ?? "\(multicastGroupAddress):\(multicastUDPPort)")"
                }
                handleSSDPMessage(.unavailableNotification, headers: headers)
            case "ssdp:update":
                guard acceptsAnnouncement(ofType: headers["nt"]) else { return }
                handleSSDPMessage(.updateNotification, headers: headers)
            case "ssdp:alive", nil:
                // A NOTIFY without NTS that still says where the device is counts as an alive.
                guard acceptsAnnouncement(ofType: headers["nt"]) else { return }
                handleSSDPMessage(.availableNotification, headers: headers)
            default:
                return
            }
        case .search, .other:
            return
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
