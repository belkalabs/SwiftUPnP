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
import Network
import os.log

public protocol DiscoveryDelegate: AnyObject {
    func sockedDidClose(_ error: Error?)
    /// Something keeps discovery from working fully. Discovery keeps retrying on its own; this is for telling the
    /// user what to check. Optional: the default implementation does nothing.
    func discoveryDidReportIssue(_ issue: SSDPDiscoveryIssue)
}

public extension DiscoveryDelegate {
    func discoveryDidReportIssue(_ issue: SSDPDiscoveryIssue) {}
}

class SSDPCocoaAsyncSocketDiscovery: SSDPDiscovery {
    /// Sends the searches, from an ephemeral port, and receives the (unicast) answers.
    private var multicastSocket: GCDAsyncUdpSocket?
    /// Bound to port 1900 and joined to the multicast group, to hear NOTIFY alive and byebye announcements. Kept
    /// apart from the search socket: answers to a search sent from port 1900 could go to another app's socket on
    /// that port.
    private var announcementSocket: GCDAsyncUdpSocket?
    weak var delegate: DiscoveryDelegate?
    var onStatusChange: ((SSDPDiscoveryStatus) -> Void)?
    var onIssue: ((SSDPDiscoveryIssue) -> Void)?
    private(set) var status = SSDPDiscoveryStatus.idle {
        didSet {
            guard status != oldValue else { return }
            onStatusChange?(status)
        }
    }
    /// From startDiscovery until stopDiscovery, whether or not a socket is open at the moment.
    private(set) var isRunning = false
    /// Bumped on every start and stop, so work scheduled for an earlier session (reopening the socket) is dropped.
    private var generation = 0
    private var pathMonitor: NWPathMonitor?
    /// The pending reopen, so that a burst of network changes leads to one reopen.
    private var reopenWorkItem: DispatchWorkItem?
    /// Reopens after errors in a row; each one waits longer, so a lasting problem doesn't keep the socket churning.
    private var failedRecoveries = 0
    /// The network path has neither Wi-Fi nor Ethernet: a search that "goes out" then reaches no TV.
    private var lacksLocalNetwork = false
    /// The local interfaces and addresses the sockets were opened for. Only a change of these reopens them.
    private var networkSignature: SSDPLocalNetworkSignature?
    /// The pending reopen of the announcement socket alone.
    private var announcementReopenWorkItem: DispatchWorkItem?
    /// An announcement socket that keeps closing is reopened at 2, 4, 8… up to 60 s, not every 2 s.
    private var announcementBackoff = SSDPBackoff(initial: 2, maximum: 60)
    private lazy var scheduler = SSDPSearchScheduler { [weak self] in
        self?.sendSearchRequests()
    }

    func startDiscovery(forTypes types: [String]) throws {
        guard multicastSocket == nil else { throw UPnPError.alreadyConnected }

        self.types = types
        generation += 1
        reopenWorkItem?.cancel()
        reopenWorkItem = nil
        isRunning = true
        failedRecoveries = 0
        announcementBackoff.reset()
        startMonitoringNetworkChanges()
        do {
            try openSockets()
        }
        catch {
            // Typically there is no network yet (e.g. the app starts before Wi-Fi is up). Keep trying, rather than
            // not discovering anything for the rest of the session.
            Logger.swiftUPnP.error("Could not open the SSDP socket: \(error.localizedDescription)")
            report(SSDPDiscoveryIssue(stage: .openSocket, error: error), failing: true)
            scheduleRecovery()
        }
    }

    /// Start discovery, or when it already runs, switch it to these types and schedule. Either way the burst of
    /// the schedule starts now.
    func startOrUpdate(forTypes types: [String], schedule: SSDPSearchSchedule) {
        if isRunning {
            self.types = types
        }
        else {
            try? startDiscovery(forTypes: types)
        }
        scheduler.start(schedule)
    }

    func stopDiscovery() {
        generation += 1
        isRunning = false
        reopenWorkItem?.cancel()
        reopenWorkItem = nil
        announcementReopenWorkItem?.cancel()
        announcementReopenWorkItem = nil
        scheduler.stop()
        pathMonitor?.cancel()
        pathMonitor = nil
        networkSignature = nil
        types = []
        lacksLocalNetwork = false
        closeSockets()
        status = .idle
    }

    /// Search with the schedule discovery has always used: at 0, 3 and 10 s.
    func searchRequest() {
        // A single M-SEARCH over UDP is easily lost, and fails outright while the system is still asking for access
        // to the local network. Repeat it a few times.
        scheduler.start(.legacy)
    }

    /// Search right away, and start the burst of the current schedule over (e.g. on a network change, or when the
    /// app comes to the foreground).
    func searchNow() {
        guard isRunning else { return }
        scheduler.restart()
    }

    private func openSockets() throws {
        try openSearchSocket()
        openAnnouncementSocket()
    }

    private func closeSockets() {
        // Cleared before closing, so the close callback knows the sockets were closed on purpose.
        let sockets = [multicastSocket, announcementSocket]
        multicastSocket = nil
        announcementSocket = nil
        sockets.forEach { $0?.close() }
    }

    private func openSearchSocket() throws {
        let multicastSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: DispatchQueue.main)
        multicastSocket.setIPv4Enabled(true)
        multicastSocket.setIPv6Enabled(true)

        do {
            try multicastSocket.enableReusePort(true)
            try multicastSocket.enableBroadcast(true)
            // Keep the remote apps' active-search socket settings when recovering the connection.
            try multicastSocket.bind(toPort: 0)
        }
        catch {
            // Not stored yet, so the close callback ignores it.
            multicastSocket.close()
            throw error
        }

        // Answers to a search are unicast, so the socket is useful even when joining the group fails (no Wi-Fi
        // address yet, or Local Network access is off): say so, but keep it.
        do {
            try multicastSocket.joinMulticastGroup(multicastGroupAddress, onInterface: "en0")
        }
        catch {
            Logger.swiftUPnP.error("Could not join the SSDP multicast group: \(error.localizedDescription)")
            report(SSDPDiscoveryIssue(stage: .joinMulticastGroup, error: error), failing: false)
        }
        // Send the searches over Wi-Fi, also when the default route is cellular (Wi-Fi without internet).
        do {
            try multicastSocket.sendIPv4Multicast(onInterface: "en0")
        }
        catch {
            Logger.swiftUPnP.debug("Could not send SSDP searches on en0: \(error.localizedDescription)")
        }

        do {
            try multicastSocket.beginReceiving()
        }
        catch {
            multicastSocket.close()
            throw error
        }

        self.multicastSocket = multicastSocket
        status = lacksLocalNetwork ? .failing(.noWiFi) : .searching
    }

    /// Hearing announcements is a bonus on top of searching, so a failure here doesn't stop discovery.
    private func openAnnouncementSocket() {
        guard announcementSocket == nil else { return }
        let announcementSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: DispatchQueue.main)
        announcementSocket.setIPv4Enabled(true)
        announcementSocket.setIPv6Enabled(false)

        do {
            try announcementSocket.enableReusePort(true)
            try announcementSocket.bind(toPort: multicastUDPPort)
            try announcementSocket.joinMulticastGroup(multicastGroupAddress, onInterface: "en0")
            try announcementSocket.beginReceiving()
        }
        catch {
            announcementSocket.close()
            Logger.swiftUPnP.error("Could not listen for SSDP announcements: \(error.localizedDescription)")
            report(SSDPDiscoveryIssue(stage: .listen, error: error), failing: false)
            return
        }

        self.announcementSocket = announcementSocket
    }

    private func sendSearchRequests() {
        guard let multicastSocket = multicastSocket else { return }

        for type in types {
            if let data = self.searchRequestData(forType: type) {
                multicastSocket.send(data, toHost: multicastGroupAddress, port: multicastUDPPort, withTimeout: 5, tag: type.hashValue)
            }
        }
    }

    private func report(_ issue: SSDPDiscoveryIssue, failing: Bool) {
        if failing {
            status = .failing(issue)
        }
        onIssue?(issue)
        delegate?.discoveryDidReportIssue(issue)
    }

    /// Open new sockets and search again, after one closed without being asked to (e.g. the network went
    /// away), or after a network change (the multicast group has to be joined on the new interface).
    private func reopenSocket(after delay: TimeInterval) {
        reopenWorkItem?.cancel()
        let generation = self.generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.isRunning, !self.types.isEmpty else { return }
            self.reopenWorkItem = nil
            self.announcementReopenWorkItem?.cancel()
            self.announcementReopenWorkItem = nil
            self.closeSockets()
            do {
                try self.openSockets()
                self.scheduler.restart()
            }
            catch {
                Logger.swiftUPnP.error("Could not reopen the SSDP socket: \(error.localizedDescription)")
                self.report(SSDPDiscoveryIssue(stage: .openSocket, error: error), failing: true)
                self.scheduleRecovery()
            }
        }
        reopenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Reopen the announcement socket alone, later each time it fails again. Searching isn't affected, so the search
    /// socket stays open and no burst starts (before, every close reopened both sockets and searched, every 2 s).
    private func reopenAnnouncementSocket() {
        announcementReopenWorkItem?.cancel()
        let generation = self.generation
        let delay = announcementBackoff.nextDelay()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation, self.isRunning, self.announcementSocket == nil else { return }
            self.announcementReopenWorkItem = nil
            self.openAnnouncementSocket()
            if self.announcementSocket == nil {
                self.reopenAnnouncementSocket()
            }
        }
        announcementReopenWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Reopen after an error, unless a reopen is already on its way: 5 s, then longer up to a minute while the
    /// errors keep coming.
    private func scheduleRecovery() {
        guard reopenWorkItem == nil else { return }
        let delay = min(5 * pow(2, Double(failedRecoveries)), 60)
        failedRecoveries += 1
        reopenSocket(after: delay)
    }

    private func startMonitoringNetworkChanges() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        var isFirstUpdate = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = SSDPLocalNetworkSignature.current(path)
            self.lacksLocalNetwork = signature.isEmpty
            if self.lacksLocalNetwork {
                self.report(.noWiFi, failing: true)
            }
            let previous = self.networkSignature
            self.networkSignature = signature
            // The first update only reports the current situation.
            guard !isFirstUpdate else {
                isFirstUpdate = false
                return
            }
            // Cellular coming and going, or the path's status changing, doesn't concern SSDP: only another Wi-Fi,
            // wired or hotspot interface, or a new address on one, needs new sockets (and the group joined again).
            guard signature != previous, !signature.isEmpty else { return }
            self.failedRecoveries = 0
            self.announcementBackoff.reset()
            self.reopenSocket(after: 1)
        }
        monitor.start(queue: DispatchQueue.main)
        pathMonitor = monitor
    }
}

extension SSDPCocoaAsyncSocketDiscovery: GCDAsyncUdpSocketDelegate {
    public func udpSocket(_ sock: GCDAsyncUdpSocket, didSendDataWithTag tag: Int) {
        guard sock === multicastSocket, !lacksLocalNetwork else { return }
        failedRecoveries = 0
        status = .searching
    }

    public func udpSocket(_ sock: GCDAsyncUdpSocket, didNotSendDataWithTag tag: Int, dueToError error: Error?) {
        // Not a reason to give up: searches are repeated, and the socket still receives announcements.
        Logger.swiftUPnP.error("Could not send SSDP search: \(error?.localizedDescription ?? "unknown error")")
        guard sock === multicastSocket else { return }
        let issue = SSDPDiscoveryIssue(stage: .send, error: error)
        report(issue, failing: true)
        // The interface the socket was bound to is gone, or has a new address.
        if issue.meansStaleSocket {
            scheduleRecovery()
        }
    }

    public func udpSocketDidClose(_ sock: GCDAsyncUdpSocket, withError error: Error?) {
        // Closed by stopDiscovery or reopenSocket: nothing to do.
        if sock === announcementSocket {
            announcementSocket = nil
            reopenAnnouncementSocket()
            return
        }
        guard sock === multicastSocket else { return }
        multicastSocket = nil
        reopenSocket(after: 2)
        report(SSDPDiscoveryIssue(stage: .socketClosed, error: error), failing: true)
        delegate?.sockedDidClose(error)
    }

    public func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        if sock === announcementSocket {
            // It works again: the next close starts the back-off over.
            announcementBackoff.reset()
        }
        processData(data)
    }
}
