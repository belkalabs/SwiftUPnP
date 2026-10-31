//
//  SSDPSearchScheduler.swift
//
//  When M-SEARCH requests go out. A single search over UDP is easily lost, and TVs that wake up late (or a
//  phone that only just joined the Wi-Fi) miss a search that is over after a few seconds.
//

import Foundation

/// When the searches of a discovery session go out.
public struct SSDPSearchSchedule: Equatable, Sendable {
    /// Seconds after the start (or a restart) at which every search target is sent, in ascending order.
    public var burst: [TimeInterval]
    /// Seconds between the searches that follow the burst, or nil to stop after the burst.
    public var repeatInterval: TimeInterval?

    public init(burst: [TimeInterval], repeatInterval: TimeInterval?) {
        self.burst = burst.sorted()
        self.repeatInterval = repeatInterval
    }

    /// What `UPnPRegistry.startDiscovery(_:requiredDefaultFiltration:)` has always done: search at 0, 3 and 10 s.
    public static let legacy = SSDPSearchSchedule(burst: [0, 3, 10], repeatInterval: nil)
    /// A burst at 0, 1, 3 and 5 s, then a search every 15 s for as long as discovery runs.
    public static let continuous = SSDPSearchSchedule(burst: [0, 1, 3, 5], repeatInterval: 15)
}

protocol SSDPCancellable {
    func cancel()
}

/// Runs work after a delay. Injected so the timing can be tested without waiting.
protocol SSDPSearchClock {
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SSDPCancellable
}

extension DispatchWorkItem: SSDPCancellable {}

/// Runs the work on a dispatch queue; the discovery engine keeps its state on the main queue.
struct DispatchQueueSearchClock: SSDPSearchClock {
    var queue: DispatchQueue = .main

    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> SSDPCancellable {
        let workItem = DispatchWorkItem(block: action)
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        return workItem
    }
}

/// Calls `search` according to a schedule. Only one step is pending at any time, so restarting or stopping never
/// leaves stray searches behind. Not thread safe: use it from the clock's queue.
final class SSDPSearchScheduler {
    private(set) var schedule: SSDPSearchSchedule
    private let clock: SSDPSearchClock
    private let search: () -> Void
    private var pending: SSDPCancellable?
    /// Bumped on every start and stop, so a step that was already on its way when it got cancelled does nothing.
    private var generation = 0
    /// True from a start until a stop, or until a schedule without a repeat interval has finished its burst.
    private(set) var isRunning = false

    init(schedule: SSDPSearchSchedule = .legacy, clock: SSDPSearchClock = DispatchQueueSearchClock(), search: @escaping () -> Void) {
        self.schedule = schedule
        self.clock = clock
        self.search = search
    }

    /// Start the burst of the given schedule now, replacing whatever was planned.
    func start(_ schedule: SSDPSearchSchedule) {
        self.schedule = schedule
        restart()
    }

    /// Start the burst of the current schedule again now: a search goes out right away (for a burst that starts
    /// at 0), and the rest of the burst and the repeats follow from here.
    func restart() {
        cancelPending()
        isRunning = true
        step(0, after: schedule.burst.first ?? 0)
    }

    func stop() {
        cancelPending()
        isRunning = false
    }

    private func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    private func step(_ index: Int, after delay: TimeInterval) {
        guard delay > 0 else {
            fire(index)
            return
        }

        let generation = self.generation
        pending = clock.schedule(after: delay) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.pending = nil
            self.fire(index)
        }
    }

    private func fire(_ index: Int) {
        guard isRunning else { return }
        search()

        let burst = schedule.burst
        let next = index + 1
        if next < burst.count {
            step(next, after: burst[next] - burst[index])
        }
        else if let interval = schedule.repeatInterval, interval > 0 {
            step(next, after: interval)
        }
        else {
            isRunning = false
        }
    }
}
