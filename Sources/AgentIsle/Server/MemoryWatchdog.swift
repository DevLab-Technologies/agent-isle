import AppKit
import Darwin
import Foundation

/// Conservative safety net against a slow memory leak in a long-lived menu-bar process.
///
/// Every `interval` seconds it reads this process's resident footprint. If that stays above
/// a high threshold across `requiredConsecutive` checks it relaunches the app in place —
/// reusing the single-instance replace behavior (`AppDelegate.terminateOtherInstances`): the
/// fresh copy launched here takes over the event port and the old one exits.
///
/// It is OFF by default (`AppSettings.autoRestartOnHighMemory`) and never restarts while a
/// session is mid-prompt (permission / question / plan), so it can't interrupt a decision.
@MainActor
final class MemoryWatchdog {
    /// Relaunch above ~800 MB — comfortably higher than a healthy footprint, so a normal
    /// session load never trips it; only a runaway leak should.
    static let thresholdBytes: UInt64 = 800 * 1024 * 1024
    /// Require two straight high readings before acting, so a momentary spike is ignored.
    static let requiredConsecutive = 2

    private let interval: TimeInterval = 60
    private var timer: Timer?
    private var consecutiveHigh = 0
    weak var store: SessionStore?

    /// Only ever relaunch a real `.app` bundle — never a `swift run` dev process.
    private var isPackagedApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Begin polling. Safe to call once at launch; self-gates on the packaged-app check and,
    /// per tick, on the user setting.
    func start(store: SessionStore) {
        self.store = store
        guard isPackagedApp else { return }
        let t = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        // Setting off: stay dormant and forget any accumulated streak.
        guard AppSettings.shared.autoRestartOnHighMemory else { consecutiveHigh = 0; return }
        guard let bytes = Self.residentBytes() else { return }

        let promptActive = (store?.attentionCount ?? 0) > 0
        let decision = Self.decide(residentBytes: bytes,
                                   threshold: Self.thresholdBytes,
                                   promptActive: promptActive,
                                   consecutiveHigh: consecutiveHigh,
                                   requiredConsecutive: Self.requiredConsecutive)
        consecutiveHigh = decision.consecutiveHigh
        if decision.shouldRestart {
            NSLog("Agent Isle: resident memory %llu MB over threshold across %d checks; relaunching.",
                  bytes / (1024 * 1024), consecutiveHigh)
            relaunch()
        }
    }

    /// Pure restart decision, factored out so it can be unit-tested without touching the
    /// process or the clock.
    ///
    /// A reading at or below `threshold` resets the streak. A high reading extends it; we
    /// restart only once the streak reaches `requiredConsecutive` AND no prompt is active.
    /// While a prompt is active the streak keeps growing (we don't reset it), so a genuine
    /// leak is acted on as soon as the user has answered.
    nonisolated static func decide(residentBytes: UInt64,
                                   threshold: UInt64,
                                   promptActive: Bool,
                                   consecutiveHigh: Int,
                                   requiredConsecutive: Int) -> (consecutiveHigh: Int, shouldRestart: Bool) {
        guard residentBytes > threshold else { return (0, false) }
        let next = consecutiveHigh + 1
        let restart = next >= requiredConsecutive && !promptActive
        return (next, restart)
    }

    /// This process's physical memory footprint in bytes (the figure Activity Monitor shows
    /// as "Memory"), or nil if the Mach call fails.
    nonisolated static func residentBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Launch a fresh instance and quit this one. The new instance's single-instance guard
    /// force-terminates any leftover copy, so the port is never contested.
    private func relaunch() {
        timer?.invalidate(); timer = nil
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
