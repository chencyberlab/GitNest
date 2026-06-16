import Foundation

/// Tail of the serialized gh-account work chain. `gh`'s active account is
/// global on-disk state, so the indicator sweep, repo listing, and project
/// init must not interleave their switch+use steps — one would flip the
/// active account out from under another. Routing them through this chain
/// makes those sections run one at a time, in call order.
@MainActor
final class GhChain {
    private var chain: Task<Void, Never> = Task {}

    func serialized<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let previous = chain
        let task = Task<T, Never> {
            _ = await previous.value
            return await runBlocking(work)
        }
        chain = Task { _ = await task.value }
        return await task.value
    }

    func serializedPreservingActiveAccount<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await serialized {
            let original = GitHub.currentLogin()
            let result = work()
            if let original, !original.isEmpty {
                GitHub.switchTo(original)
            }
            return result
        }
    }

    /// Wait until every previously queued operation has finished.
    func awaitDrain() async {
        _ = await chain.value
    }
}
