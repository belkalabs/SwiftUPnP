//
//  SSDPSearchSchedulerTests.swift
//

import XCTest
@testable import SwiftUPnP

/// A clock that only moves when the test says so.
private final class ManualClock: SSDPSearchClock {
    private final class Task: SSDPCancellable {
        let due: TimeInterval
        let order: Int
        let action: () -> Void
        var isCancelled = false

        init(due: TimeInterval, order: Int, action: @escaping () -> Void) {
            self.due = due
            self.order = order
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private var tasks = [Task]()
    private var scheduled = 0

    var pendingCount: Int {
        tasks.filter { !$0.isCancelled }.count
    }

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SSDPCancellable {
        scheduled += 1
        let task = Task(due: now + delay, order: scheduled, action: action)
        tasks.append(task)
        return task
    }

    /// Move to `time`, running everything that becomes due on the way, in order.
    func advance(to time: TimeInterval) {
        while let next = tasks.filter({ !$0.isCancelled && $0.due <= time }).min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            tasks.removeAll { $0 === next }
            now = next.due
            next.action()
        }
        tasks.removeAll { $0.isCancelled }
        now = time
    }
}

final class SSDPSearchSchedulerTests: XCTestCase {
    private var clock: ManualClock!
    private var searches: [TimeInterval]!
    private var scheduler: SSDPSearchScheduler!

    override func setUp() {
        clock = ManualClock()
        searches = []
        scheduler = SSDPSearchScheduler(clock: clock) { [unowned self] in
            self.searches.append(self.clock.now)
        }
    }

    func testContinuousScheduleBurstsThenRepeatsEveryFifteenSeconds() {
        scheduler.start(.continuous)
        XCTAssertEqual(searches, [0], "The first search goes out right away")

        clock.advance(to: 65)
        XCTAssertEqual(searches, [0, 1, 3, 5, 20, 35, 50, 65])
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(clock.pendingCount, 1, "Only the next search is ever pending")
    }

    func testLegacyScheduleSearchesAtZeroThreeAndTenThenStops() {
        scheduler.start(.legacy)
        clock.advance(to: 120)

        XCTAssertEqual(searches, [0, 3, 10])
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testSearchNowStartsTheBurstOver() {
        scheduler.start(.continuous)
        clock.advance(to: 27)
        XCTAssertEqual(searches, [0, 1, 3, 5, 20])

        scheduler.restart()
        clock.advance(to: 60)
        XCTAssertEqual(searches, [0, 1, 3, 5, 20, 27, 28, 30, 32, 47])
        XCTAssertEqual(clock.pendingCount, 1)
    }

    func testRestartingAFinishedLegacyScheduleSearchesAgain() {
        scheduler.start(.legacy)
        clock.advance(to: 30)
        scheduler.restart()
        clock.advance(to: 60)

        XCTAssertEqual(searches, [0, 3, 10, 30, 33, 40])
    }

    func testStopCancelsEverythingPlanned() {
        scheduler.start(.continuous)
        clock.advance(to: 2)
        scheduler.stop()
        clock.advance(to: 100)

        XCTAssertEqual(searches, [0, 1])
        XCTAssertFalse(scheduler.isRunning)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testSwitchingScheduleReplacesThePlannedSearches() {
        scheduler.start(.legacy)
        clock.advance(to: 4)
        scheduler.start(.continuous)
        clock.advance(to: 25)

        XCTAssertEqual(searches, [0, 3, 4, 5, 7, 9, 24])
        XCTAssertEqual(scheduler.schedule, .continuous)
    }

    func testABurstThatDoesNotStartAtZero() {
        scheduler.start(SSDPSearchSchedule(burst: [2, 1], repeatInterval: 10))
        XCTAssertEqual(searches, [])

        clock.advance(to: 22)
        XCTAssertEqual(searches, [1, 2, 12, 22])
    }

    func testStepsThatFireAfterACancelDoNothing() {
        // A dispatch work item can already be running when it is cancelled; the scheduler must not act on it.
        final class LeakyClock: SSDPSearchClock {
            var actions = [() -> Void]()
            struct Ignored: SSDPCancellable { func cancel() {} }
            func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SSDPCancellable {
                actions.append(action)
                return Ignored()
            }
        }
        let clock = LeakyClock()
        var count = 0
        let scheduler = SSDPSearchScheduler(clock: clock) { count += 1 }

        scheduler.start(.continuous)
        scheduler.stop()
        clock.actions.forEach { $0() }

        XCTAssertEqual(count, 1)
    }

    func testDefaultSchedules() {
        XCTAssertEqual(SSDPSearchSchedule.continuous.burst, [0, 1, 3, 5])
        XCTAssertEqual(SSDPSearchSchedule.continuous.repeatInterval, 15)
        XCTAssertEqual(SSDPSearchSchedule.legacy.burst, [0, 3, 10])
        XCTAssertNil(SSDPSearchSchedule.legacy.repeatInterval)
        XCTAssertEqual(UPnPRegistry.tvSearchTargets, ["ssdp:all",
                                                      "upnp:rootdevice",
                                                      "urn:dial-multiscreen-org:service:dial:1",
                                                      "urn:schemas-upnp-org:device:tvdevice:1",
                                                      "roku:ecp"])
    }
}

final class SSDPDiscoveryIssueTests: XCTestCase {
    func testLikelyCauses() {
        let denied = SSDPDiscoveryIssue(stage: .send, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EHOSTUNREACH)))
        XCTAssertEqual(denied.likelyCause, .localNetworkDenied)
        XCTAssertEqual(denied.errorCode, 65)
        XCTAssertFalse(denied.meansStaleSocket)

        XCTAssertEqual(SSDPDiscoveryIssue(stage: .send, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))).likelyCause, .localNetworkDenied)

        let gone = SSDPDiscoveryIssue(stage: .send, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRNOTAVAIL)))
        XCTAssertEqual(gone.likelyCause, .noWiFi)
        XCTAssertTrue(gone.meansStaleSocket)

        let unknownInterface = SSDPDiscoveryIssue(stage: .joinMulticastGroup,
                                                  error: NSError(domain: "GCDAsyncUdpSocketErrorDomain", code: 2,
                                                                 userInfo: [NSLocalizedDescriptionKey: "Unknown interface."]))
        XCTAssertEqual(unknownInterface.likelyCause, .noWiFi)
        XCTAssertEqual(unknownInterface.message, "Unknown interface.")

        XCTAssertEqual(SSDPDiscoveryIssue(stage: .listen, error: NSError(domain: NSPOSIXErrorDomain, code: Int(EADDRINUSE))).likelyCause, .unknown)
        XCTAssertEqual(SSDPDiscoveryIssue(stage: .socketClosed, error: nil).likelyCause, .unknown)
    }
}
