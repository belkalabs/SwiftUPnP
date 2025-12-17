//
//  SSDPCocoaAsyncSocketDiscovery.swift
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
import Combine
import CocoaAsyncSocket
import os.log

public protocol DiscoveryDelegate: AnyObject {
    func sockedDidClose(_ error: Error?)
}

class SSDPCocoaAsyncSocketDiscovery: SSDPDiscovery {
    private var multicastSocket: GCDAsyncUdpSocket?
    
    private var queue = DispatchQueue(label: "com.tvcontrol.upnp")
    
    weak var delegate: DiscoveryDelegate?
    
    func startDiscovery(forTypes types: [String]) throws {
        guard multicastSocket == nil else { throw UPnPError.alreadyConnected }
        
        let multicastSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: queue)
        multicastSocket.setIPv4Enabled(true)
        multicastSocket.setIPv6Enabled(false)

        
        try multicastSocket.enableReusePort(true)
        try multicastSocket.enableBroadcast(true)
        try multicastSocket.bind(toPort: 0)
        try multicastSocket.joinMulticastGroup(multicastGroupAddress, onInterface: "en0")
        try multicastSocket.beginReceiving()

        self.types = types
        self.multicastSocket = multicastSocket
        Logger.swiftUPnP.info("Discovery started")
    }
    
    func setDelegate(delegate: DiscoveryDelegate) {
        self.delegate = delegate
    }
    
    func stopDiscovery() {
        guard let multicastSocket = multicastSocket else { return }
        
        multicastSocket.close()
        self.multicastSocket = nil
        types = []
        Logger.swiftUPnP.info("Discovery stopped")
    }
    
    func searchRequest() {
        guard let multicastSocket = multicastSocket else {
            Logger.swiftUPnP.error("Can't stop search request: multicastSocket is nil")
            return
        }

        for type in types {
            if let data = self.searchRequestData(forType: type) {
                Logger.swiftUPnP.log("Sending \(String(data: data, encoding: .utf8) ?? "No data", privacy: .public) to \(self.multicastGroupAddress, privacy: .public):\(self.multicastUDPPort, privacy: .public)")
                multicastSocket.send(data, toHost: multicastGroupAddress, port: multicastUDPPort, withTimeout: 5, tag: type.hashValue)
            } else {
                Logger.swiftUPnP.error("No search request data for type \(type, privacy: .public)")
            }
        }
    }
}

extension SSDPCocoaAsyncSocketDiscovery: GCDAsyncUdpSocketDelegate {
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        Logger.swiftUPnP.error("Received error while sending UDP packet: \(error?.localizedDescription ?? "No description", privacy: .public)")
        stopDiscovery()
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didNotConnect error: (any Error)?) {
        Logger.swiftUPnP.error("Can't connect to socket, error: \(error?.localizedDescription ?? "No description", privacy: .public)")
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didConnectToAddress address: Data) {
        Logger.swiftUPnP.log("Connected to address \(String(data: address, encoding: .utf8) ?? "No address", privacy: .public)")
    }
    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {
        Logger.swiftUPnP.log("Sended data with tag \(tag, privacy: .public)")
    }
    
    public func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        Logger.swiftUPnP.error("Upd socket did close: \(error?.localizedDescription ?? "No description", privacy: .public)")
        delegate?.sockedDidClose(error)
    }
    
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        Logger.swiftUPnP.info("Received message in udp socket: \(String(data: data, encoding: .utf8) ?? "No message", privacy: .public) from \(String(data: data, encoding: .utf8) ?? "No message", privacy: .public)")
        processData(data)
    }
}
