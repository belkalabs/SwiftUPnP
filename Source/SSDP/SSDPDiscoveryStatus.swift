//
//  SSDPDiscoveryStatus.swift
//
//  What keeps SSDP discovery from working, so an app can tell "no Wi-Fi" or "Local Network access is off" apart
//  from "no TV answered".
//

import Foundation

/// Whether SSDP discovery can search right now.
public enum SSDPDiscoveryStatus: Equatable, Sendable {
    /// Discovery is not running.
    case idle
    /// The search socket is open, and the last search went out without an error.
    case searching
    /// Searches can't go out. Discovery keeps retrying on its own (on network changes, and on its schedule).
    case failing(SSDPDiscoveryIssue)
}

/// Something that went wrong in SSDP discovery. Discovery recovers on its own where it can; this is for telling the
/// user what to check.
public struct SSDPDiscoveryIssue: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Stage: String, Sendable {
        /// The network path has no Wi-Fi or wired interface.
        case network
        /// Creating or binding the search socket.
        case openSocket
        /// Joining the SSDP multicast group (239.255.255.250) on the Wi-Fi interface.
        case joinMulticastGroup
        /// Opening the socket on port 1900 that hears NOTIFY announcements. Searching still works without it.
        case listen
        /// Sending an M-SEARCH.
        case send
        /// A socket closed without being asked to.
        case socketClosed
    }

    /// A best guess from the error code. The OS reports a denied Local Network permission with the same errors as
    /// some routing problems, so an app should combine this with its own permission check.
    public enum LikelyCause: String, Sendable {
        /// No Wi-Fi interface with an address.
        case noWiFi
        /// The Local Network permission is off (or the multicast entitlement is missing).
        case localNetworkDenied
        case unknown
    }

    public let stage: Stage
    public let likelyCause: LikelyCause
    /// The domain and code of the underlying error, for diagnostics.
    public let errorDomain: String?
    public let errorCode: Int?
    public let message: String

    public init(stage: Stage, likelyCause: LikelyCause, errorDomain: String? = nil, errorCode: Int? = nil, message: String) {
        self.stage = stage
        self.likelyCause = likelyCause
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.message = message
    }

    init(stage: Stage, error: Error?) {
        guard let error else {
            self.init(stage: stage, likelyCause: .unknown, message: "unknown error")
            return
        }
        let nsError = error as NSError
        self.init(stage: stage,
                  likelyCause: Self.likelyCause(domain: nsError.domain, code: nsError.code),
                  errorDomain: nsError.domain,
                  errorCode: nsError.code,
                  message: nsError.localizedDescription)
    }

    static let noWiFi = SSDPDiscoveryIssue(stage: .network, likelyCause: .noWiFi, message: "The network has no Wi-Fi or wired interface")

    public var description: String {
        "\(stage.rawValue): \(likelyCause.rawValue) (\(errorDomain ?? "-") \(errorCode.map(String.init) ?? "-")) \(message)"
    }

    static func likelyCause(domain: String, code: Int) -> LikelyCause {
        switch domain {
        case NSPOSIXErrorDomain:
            switch code {
            case Int(EHOSTUNREACH), Int(EPERM), Int(EACCES):
                // What sendto reports for local network traffic the user didn't allow.
                return .localNetworkDenied
            case Int(ENETDOWN), Int(ENETUNREACH), Int(EADDRNOTAVAIL), Int(ENXIO):
                return .noWiFi
            default:
                return .unknown
            }
        case "GCDAsyncUdpSocketErrorDomain":
            // GCDAsyncUdpSocketBadParamError: "Unknown interface" when en0 has no address.
            return code == 2 ? .noWiFi : .unknown
        default:
            return .unknown
        }
    }

    /// Errors after which the socket is unlikely to work again, typically because the interface it was bound
    /// to went away or got a new address.
    var meansStaleSocket: Bool {
        guard errorDomain == NSPOSIXErrorDomain, let errorCode else { return false }
        return [ENETDOWN, ENETUNREACH, EADDRNOTAVAIL, EBADF, ENOTCONN].map(Int.init).contains(errorCode)
    }
}
