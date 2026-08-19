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

    func testForgetAllChannelsInvalidatesEveryTrackedAttempt() {
        let channelA = UUID(), channelB = UUID()
        let generationA = MessageSender.beginAttempt(on: channelA)
        let generationB = MessageSender.beginAttempt(on: channelB)
        MessageSender.forgetAllChannels()
        XCTAssertFalse(MessageSender.isCurrentAttempt(generationA, on: channelA))
        XCTAssertFalse(MessageSender.isCurrentAttempt(generationB, on: channelB))
    }
}
