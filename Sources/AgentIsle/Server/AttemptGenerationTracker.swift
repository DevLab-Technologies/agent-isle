import os

/// Per-channel counter guarding against a stale, slow-to-complete async attempt acting (or
/// reporting an outcome) after a *later* attempt on the same channel has already superseded
/// it. `OSAllocatedUnfairLock` makes the store itself genuinely `Sendable`, so these methods
/// need no actor isolation and are safe to call from any thread — a caller only needs a
/// `Hashable` value that names the channel, not its own generation bookkeeping.
///
/// Each consumer should own its own instance rather than share one globally: forgetting a
/// channel (or every channel) only makes sense within one consumer's own set of channels,
/// and a shared registry would let one consumer's cleanup silently invalidate another's
/// unrelated in-flight attempt.
final class AttemptGenerationTracker: @unchecked Sendable {
    private let generations = OSAllocatedUnfairLock<[AnyHashable: Int]>(initialState: [:])

    func begin(on channel: AnyHashable) -> Int {
        generations.withLock { values in
            let next = (values[channel] ?? 0) + 1
            values[channel] = next
            return next
        }
    }

    func isCurrent(_ generation: Int, on channel: AnyHashable) -> Bool {
        generations.withLock { $0[channel] == generation }
    }

    /// Forget a channel's tracked attempt. Call when the channel's owner (e.g. a removed
    /// session) can no longer act on an outcome, so the store doesn't grow forever.
    func forget(_ channel: AnyHashable) {
        generations.withLock { $0[channel] = nil }
    }

    /// Forget every tracked channel at once — cheaper than forgetting each individually when
    /// all owning state is being reset together.
    func forgetAll() {
        generations.withLock { $0.removeAll() }
    }
}
