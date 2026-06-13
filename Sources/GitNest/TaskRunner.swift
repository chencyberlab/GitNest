import Foundation

/// Shell commands block their thread on semaphores/`waitpid`/`waitUntilExit`.
/// A `Task.detached` runs that on Swift's cooperative thread pool, which is only
/// ~CPU-core wide — a few concurrent commands (pull on several repos while timers
/// tick) could park every pool thread and stall unrelated async work. Dispatch to
/// a dedicated concurrent queue instead so those waits never touch the pool.
private let blockingQueue = DispatchQueue(label: "org.gitnest.shell",
                                          qos: .userInitiated,
                                          attributes: .concurrent)

/// Run blocking work off the main actor; result lands back on the main actor.
func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        blockingQueue.async { continuation.resume(returning: work()) }
    }
}
