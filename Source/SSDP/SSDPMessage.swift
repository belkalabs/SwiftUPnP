//
//  SSDPMessage.swift
//
//  Lenient parsing of SSDP datagrams. TVs are sloppy senders: header names in any case, LF-only line
//  endings, padding around values, repeated headers and missing optional ones all occur in the wild.
//

import Foundation

/// A parsed SSDP datagram: a search response, a NOTIFY announcement, or another control point's M-SEARCH.
struct SSDPMessage: Equatable {
    enum Kind: Equatable {
        /// `HTTP/1.x 200`: an answer to one of our searches.
        case searchResponse
        /// `NOTIFY * HTTP/1.1`: an alive, update or byebye announcement.
        case notification
        /// `M-SEARCH * HTTP/1.1`: someone's search, including our own looped back.
        case search
        /// An HTTP error response, or a start line and headers that say nothing about a device.
        case other
    }

    let kind: Kind
    let startLine: String
    /// Header names are lowercased, names and values trimmed. The first non-empty value of a repeated header wins.
    let headers: [String: String]

    init?(data: Data) {
        // Server strings with Latin-1 characters are not valid UTF-8; that is no reason to drop the packet.
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        self.init(text)
    }

    init?(_ text: String) {
        var startLine: String?
        var headers = [String: String]()

        // enumerateLines treats \r\n, \n and \r alike.
        text.enumerateLines { rawLine, stop in
            let line = rawLine.trimmingCharacters(in: Self.padding)
            guard startLine != nil else {
                // Some senders put an empty line before the start line.
                if !line.isEmpty {
                    startLine = line
                }
                return
            }
            guard !line.isEmpty else {
                // The empty line ends the headers; SSDP messages have no body worth reading.
                stop = true
                return
            }
            guard let colon = line.firstIndex(of: ":") else { return }

            let name = line[..<colon].trimmingCharacters(in: Self.padding).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: Self.padding)
            guard !name.isEmpty else { return }
            if headers[name]?.isEmpty ?? true {
                headers[name] = value
            }
        }

        guard let startLine else { return nil }
        self.startLine = startLine
        self.headers = headers
        self.kind = Self.kind(startLine: startLine, headers: headers)
    }

    var notificationSubtype: String? {
        headers["nts"]?.lowercased()
    }

    private static let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static func kind(startLine: String, headers: [String: String]) -> Kind {
        let tokens = startLine.uppercased().split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let method = tokens.first else { return .other }

        if method.hasPrefix("HTTP/") {
            // "HTTP/1.1 200 OK", but also "HTTP/1.0 200" without a reason phrase.
            return tokens.count > 1 && tokens[1] == "200" ? .searchResponse : .other
        }
        if method == "NOTIFY" {
            return .notification
        }
        if method == "M-SEARCH" {
            return .search
        }

        // An unknown start line: judge the packet by what it carries rather than dropping it.
        if headers["nts"] != nil, headers["usn"] != nil {
            return .notification
        }
        if headers["usn"] != nil, headers["location"] != nil {
            return .searchResponse
        }
        return .other
    }
}

/// The USN header, e.g. `uuid:2f402f80-da50-11e1-9b23-00178809ea66::urn:schemas-upnp-org:device:MediaRenderer:1`.
///
/// Not every device follows the `uuid:<id>::<type>` form: Roku answers with `uuid:roku:ecp:<serial>`, and a device's
/// own announcement is just `uuid:<id>`.
struct SSDPUniqueServiceName: Equatable {
    let rawValue: String
    /// The device part, as sent and with its `uuid:` prefix: what `UPnPDevice.uuid` has always held.
    let device: String
    /// The device's UUID without the `uuid:` prefix.
    let uuid: String
    /// The device or service type after `::`, if any.
    let type: String?

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let device: String
        if let separator = value.range(of: "::") {
            device = String(value[..<separator.lowerBound])
            let type = String(value[separator.upperBound...])
            self.type = type.isEmpty ? nil : type
        }
        else {
            device = value
            self.type = nil
        }
        guard !device.isEmpty else { return nil }

        self.rawValue = value
        self.device = device
        self.uuid = device.lowercased().hasPrefix("uuid:") ? String(device.dropFirst(5)) : device
    }
}
