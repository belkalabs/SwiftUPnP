//
//  SSDPNetworkChange.swift
//

import Foundation
import Network

/// The interfaces SSDP can reach devices on, with their IPv4 addresses. Discovery reopens its sockets only when this
/// changes: every path update used to reopen them and start a search burst, also when only cellular came or went.
struct SSDPLocalNetworkSignature: Equatable {
    /// "name=address", sorted. The address is "-" while the interface has none.
    let interfaces: [String]

    /// No Wi-Fi, wired or Personal Hotspot interface: searches reach no device.
    var isEmpty: Bool { interfaces.isEmpty }

    /// - Parameters:
    ///   - interfaces: the path's available interfaces.
    ///   - address: the IPv4 address of an interface, by name, or nil.
    static func make(interfaces: [(name: String, type: NWInterface.InterfaceType)], address: (String) -> String?) -> SSDPLocalNetworkSignature {
        var entries = [String]()
        for interface in interfaces {
            let ipv4 = address(interface.name)
            switch interface.type {
            case .wifi, .wiredEthernet:
                entries.append("\(interface.name)=\(ipv4 ?? "-")")
            case .other where interface.name.hasPrefix("bridge") && ipv4 != nil:
                // Personal Hotspot: the TV is a client of this phone.
                entries.append("\(interface.name)=\(ipv4!)")
            default:
                continue
            }
        }
        return SSDPLocalNetworkSignature(interfaces: Array(Set(entries)).sorted())
    }

    static func current(_ path: NWPath) -> SSDPLocalNetworkSignature {
        make(interfaces: path.availableInterfaces.map { (name: $0.name, type: $0.type) }) { name in
            guard let address = try? IPHelper.getInterfaceIPAddress(interfaceName: name), address != "0.0.0.0" else { return nil }
            return address
        }
    }
}

/// Delays that double after each failure in a row, up to a maximum.
struct SSDPBackoff {
    let initial: TimeInterval
    let maximum: TimeInterval
    private(set) var failures = 0

    init(initial: TimeInterval, maximum: TimeInterval) {
        self.initial = initial
        self.maximum = maximum
    }

    mutating func nextDelay() -> TimeInterval {
        let delay = min(initial * pow(2, Double(failures)), maximum)
        failures += 1
        return delay
    }

    mutating func reset() {
        failures = 0
    }
}
