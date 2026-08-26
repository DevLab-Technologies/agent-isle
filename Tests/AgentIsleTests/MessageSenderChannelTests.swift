import XCTest
@testable import AgentIsle

/// The generation-guard that drops a stale send completion once a later send on the same
/// channel has already resolved. Lives in `MessageSender` (not a caller like `SessionStore`)
/// because "exactly one outcome per channel, most-recent-wins" is this module's own delivery
/// contract — every caller just needs a `Hashable` channel value, not its own bookkeeping.
/// `beginAttempt`/`isCurrentAttempt` are exposed (not `private`) so the rule is testable
/// without driving a real `MessageSender.send`.
@MainActor
final class MessageSenderChannelTests: XCTestCase {

    func testDifferentChannelsDoNotInvalidateEachOther() {
        let channelA = UUID(), channelB = UUID()
        let generationA = MessageSender.beginAttempt(on: channelA)
        let generationB = MessageSender.beginAttempt(on: channelB)

        XCTAssertTrue(MessageSender.isCurrentAttempt(generationA, on: channelA))
        XCTAssertTrue(MessageSender.isCurrentAttempt(generationB, on: channelB))
    }

    /// A second attempt on the SAME channel still supersedes the first — the guard this
    /// replaced must keep doing its original job.
    func testASecondAttemptOnTheSameChannelInvalidatesTheFirst() {
        let channel = UUID()
        let first = MessageSender.beginAttempt(on: channel)
        let second = MessageSender.beginAttempt(on: channel)

        XCTAssertFalse(MessageSender.isCurrentAttempt(first, on: channel))
        XCTAssertTrue(MessageSender.isCurrentAttempt(second, on: channel))
    }

    /// Forgetting a channel (e.g. its owning session was removed) invalidates its tracked
    /// attempt, so a completion that arrives afterward is dropped rather than acted on.
    func testForgettingAChannelInvalidatesItsAttempt() {
        let channel = UUID()
        let generation = MessageSender.beginAttempt(on: channel)
        MessageSender.forgetChannel(channel)
        XCTAssertFalse(MessageSender.isCurrentAttempt(generation, on: channel))
    }

    /// Forgetting a channel that never had an attempt must stay a true no-op — not plant an
    /// entry that lingers forever. `clearAllSendErrors` forgets all three `SendKind`s for
    /// every session on removal/archival/`.done`, regardless of whether that kind was ever
    /// actually sent, so a channel that was never used must not leave a trace: the next
    /// attempt on it should still start at generation 1.
    func testForgettingAnUntouchedChannelLeavesNoTrace() {
        let channel = UUID()
        MessageSender.forgetChannel(channel)
        let generation = MessageSender.beginAttempt(on: channel)
        XCTAssertEqual(generation, 1)
    }

    func testForgetAllChannelsInvalidatesEveryTrackedAttempt() {
        let channelA = UUID(), channelB = UUID()
        let generationA = MessageSender.beginAttempt(on: channelA)
        let generationB = MessageSender.beginAttempt(on: channelB)
        MessageSender.forgetAllChannels()
        XCTAssertFalse(MessageSender.isCurrentAttempt(generationA, on: channelA))
        XCTAssertFalse(MessageSender.isCurrentAttempt(generationB, on: channelB))
    }

    /// The actual scenario the lock-protected store exists for: `runScriptOffMain` reads
    /// currency from a background queue while the main actor can be starting new attempts at
    /// the same time. `beginAttempt`/`isCurrentAttempt` are `nonisolated` specifically so this
    /// is callable — and safe — off the main actor; a data race here would corrupt the count
    /// (lost increments) rather than merely produce a wrong-but-consistent answer.
    func testConcurrentAttemptsFromMultipleThreadsLoseNoUpdates() {
        let channel = UUID()
        let iterations = 2_000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            _ = MessageSender.beginAttempt(on: channel)
        }
        let final = MessageSender.beginAttempt(on: channel)
        XCTAssertEqual(final, iterations + 1)
    }
}
