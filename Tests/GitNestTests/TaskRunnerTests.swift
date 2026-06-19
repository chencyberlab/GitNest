import XCTest
@testable import GitNest

final class TaskRunnerTests: XCTestCase {
    /// Lock-guarded peak-concurrency tracker. A reference type so the `@Sendable`
    /// `runBlocking` closures can mutate shared state without capturing a `var`.
    private final class ConcurrencyTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var peak = 0

        func enter() {
            lock.lock(); defer { lock.unlock() }
            current += 1
            peak = max(peak, current)
        }
        func leave() {
            lock.lock(); current -= 1; lock.unlock()
        }
        var observedPeak: Int {
            lock.lock(); defer { lock.unlock() }
            return peak
        }
    }

    /// `runBlocking` must never run more than its cap concurrently. Removing the
    /// semaphore would let this fan out to `taskCount`, blowing past the cap.
    func testRunBlockingHonorsConcurrencyCap() async {
        let tracker = ConcurrencyTracker()
        let taskCount = runBlockingConcurrencyCap * 3

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    await runBlocking {
                        tracker.enter()
                        // Hold the slot briefly so calls genuinely overlap.
                        Thread.sleep(forTimeInterval: 0.05)
                        tracker.leave()
                    }
                }
            }
        }

        XCTAssertLessThanOrEqual(tracker.observedPeak, runBlockingConcurrencyCap,
                                 "runBlocking exceeded its concurrency cap")
        XCTAssertGreaterThan(tracker.observedPeak, 1,
                             "expected real overlap so the cap is actually exercised")
    }

    /// The result of the work must still be delivered back to the caller unchanged.
    func testRunBlockingReturnsValue() async {
        let value = await runBlocking { 21 * 2 }
        XCTAssertEqual(value, 42)
    }
}
