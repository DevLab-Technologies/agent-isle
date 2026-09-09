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

    /// Forget a channel's tracked attempt. Call when the channel's owner (e.g. a removed or
    /// archived session) can no longer act on an outcome. Bumps the generation rather than
    /// deleting the entry: a channel key can be reused (e.g. a session archived and later
    /// reactivated, or a re-created attempt on the same name), and deleting would let a fresh
    /// `begin` restart from 1 — colliding with a still in-flight, now-abandoned attempt at
    /// that same generation number, which could then have its stale outcome misapplied as the
    /// new attempt's result. Only bumps an entry that already exists: a caller that forgets
    /// every channel for an owner regardless of whether any of them were ever actually used
    /// would otherwise plant a permanent, never-cleaned entry for every such no-op.
    func forget(_ channel: AnyHashable) {
        generations.withLock { values in
            guard let current = values[channel] else { return }
            values[channel] = current + 1
        }
    }

    /// Forget every tracked channel at once — cheaper than forgetting each individually when
    /// all owning state is being reset together.
    func forgetAll() {
        generations.withLock { $0.removeAll() }
    }
}
