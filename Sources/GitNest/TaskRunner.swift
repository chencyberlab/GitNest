import Foundation

/// Shell commands block their thread on semaphores/`waitpid`/`waitUntilExit`.
/// A `Task.detached` runs that on Swift's cooperative thread pool, which is only
/// ~CPU-core wide — a few concurrent commands (pull on several repos while timers
/// tick) could park every pool thread and stall unrelated async work. Dispatch to
/// a dedicated concurrent queue instead so those waits never touch the pool.
private let blockingQueue = DispatchQueue(label: "org.gitnest.shell",
                                          qos: .userInitiated,
                                          attributes: .concurrent)

/// Ceiling on how many blocking commands run at once. Each `runBlocking` typically
/// spawns and waits on an external process (git/gh/ssh); without a bound, a burst —
/// many row actions plus the two refresh timers firing together — could fan the
/// dedicated queue out into a thread-and-process storm. The limit is deliberately
/// generous: normal use stays far below it (status scans batch every repo inside a
/// single `runBlocking`, and the gh chain serializes its own work), so this only
/// trims pathological spikes. It can add latency but never deadlock — no blocking
/// command waits on another, so there is no cycle for the gate to stall on.
let runBlockingConcurrencyCap = 12
private let blockingConcurrencyLimit = DispatchSemaphore(value: runBlockingConcurrencyCap)

/// Run blocking work off the main actor; result lands back on the main actor.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        blockingQueue.async {
            blockingConcurrencyLimit.wait()
            defer { blockingConcurrencyLimit.signal() }
            continuation.resume(returning: work())
        }
    }
}
