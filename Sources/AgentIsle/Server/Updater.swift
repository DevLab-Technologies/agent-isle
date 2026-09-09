import AppKit
import Foundation

/// Which releases the updater considers.
///
/// `stable` mirrors the long-standing behavior: only full (non-pre-release) releases.
/// `preRelease` also considers the latest pre-release tag, so testers on the beta channel
/// pick up release candidates before they're promoted to stable.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, preRelease
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable:     return "Stable"
        case .preRelease: return "Beta (includes pre-releases)"
        }
    }
}

/// A GitHub release reduced to the fields the channel selector needs. Kept separate from the
/// download-bearing `FetchedRelease` so the selection logic stays pure and unit-testable.
struct ReleaseInfo: Equatable {
    let tag: String
    var isPrerelease = false
    var isDraft = false

    /// The tag without a leading "v", e.g. "1.2.0" for "v1.2.0".
    var cleanVersion: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
}

/// Checks GitHub Releases for a newer build and installs it in place.
///
/// Distribution is a notarized `Agent-Isle.zip` attached to each GitHub release
/// (`DevLab-Technologies/agent-isle`). On a check we list recent releases, pick the newest
/// one appropriate for the current channel, and compare its tag to this build's
/// `CFBundleShortVersionString`; if it's newer we either prompt the user or — when
/// "Automatically Install Updates" is on — download and swap the app bundle, then relaunch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private static let repo = "DevLab-Technologies/agent-isle"
    /// List endpoint (newest first). Unlike `/releases/latest` it includes pre-releases, so
    /// the channel selector can pick between them.
    private static let releasesListAPI =
        URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!
    static let releasesPage =
        URL(string: "https://github.com/\(repo)/releases/latest")!
    /// Developer ID Team ID that signs official GitHub releases
    /// (`AHMED ELKHAYYAT (ZS3A435WC2)`). Change only if the Apple team changes;
    /// auto-update must not accept another signer without an explicit commit.
    nonisolated static let expectedTeamID = "ZS3A435WC2"
    /// `codesign -R=` requirement: official Developer ID Application signing chain
    /// from this team. `--verify --strict` alone accepts ad-hoc signatures; this does not.
    nonisolated static var codesignRequirement: String {
        "anchor apple generic"
        + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
        + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        + " and certificate leaf[subject.OU] = \(expectedTeamID)"
    }

    private let autoInstallKey = "autoInstallUpdates"
    private let skippedKey = "skippedUpdateVersion"
    private let channelKey = "updateChannel"
    private let checkInterval: TimeInterval = 6 * 3600
    private var fm: FileManager { .default }
    private var timer: Timer?
    private var isRunning = false   // guards against overlapping checks/dialogs

    /// Session store, used to avoid auto-installing while the notch is mid-approval.
    weak var store: SessionStore?

    /// User setting: install updates automatically instead of prompting.
    var autoInstall: Bool {
        get { UserDefaults.standard.bool(forKey: autoInstallKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoInstallKey) }
    }
    /// User setting: which release channel to follow. Defaults to `.stable`.
    var channel: UpdateChannel {
        get { UpdateChannel(rawValue: UserDefaults.standard.string(forKey: channelKey) ?? "") ?? .stable }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: channelKey) }
    }
    /// A version the user chose to skip — we won't re-prompt for it (manual checks ignore this).
    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: skippedKey) }
        set { UserDefaults.standard.set(newValue, forKey: skippedKey) }
    }

    /// This build's marketing version, e.g. "1.1". Falls back to "0" when running
    /// unpackaged (`swift run`), where there's no Info.plist.
    let currentVersion =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

    /// Only auto-update a real `.app` bundle — never a `swift run` dev process.
    private var isPackagedApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: - Scheduling

    /// Begin automatic checks: once shortly after launch, then every few hours.
    func start() {
        guard isPackagedApp else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Task { @MainActor in Updater.shared.checkForUpdates(userInitiated: false) }
        }
        let t = Timer(timeInterval: checkInterval, repeats: true) { _ in
            Task { @MainActor in Updater.shared.checkForUpdates(userInitiated: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Check now. `userInitiated` surfaces "you're up to date" / error dialogs and
    /// ignores a previously skipped version.
    func checkForUpdates(userInitiated: Bool) {
        guard !isRunning else { return }
        isRunning = true
        Task {
            await performCheck(userInitiated: userInitiated)
            isRunning = false
        }
    }

    private func performCheck(userInitiated: Bool) async {
        guard let releases = await fetchReleases() else {
            if userInitiated { showInfo("Couldn't check for updates",
                                        "Please try again later, or visit the releases page.") }
            return
        }
        guard let chosen = Self.selectRelease(channel: channel, from: releases.map(\.info)),
              let release = releases.first(where: { $0.info.tag == chosen.tag }),
              Self.isNewer(chosen.tag, than: currentVersion) else {
            if userInitiated { showInfo("You're up to date",
                                        "Agent Isle \(currentVersion) is the latest version on the \(channel.title) channel.") }
            return
        }
        if !userInitiated, chosen.tag == skippedVersion { return }

        if autoInstall {
            // Don't yank the app out from under a pending approval on a background
            // check — retry on the next tick. A manual check installs immediately.
            if !userInitiated, (store?.attentionCount ?? 0) > 0 { return }
            await downloadAndInstall(release)
        } else {
            promptForUpdate(release)
        }
    }

    // MARK: - Channel selection

    /// Pick the newest release appropriate for `channel`, or nil if none qualify. Pure and
    /// side-effect free so it can be unit-tested against synthetic release lists.
    ///
    /// Drafts are always excluded. `stable` keeps only full releases; `preRelease` considers
    /// pre-releases too. Among the candidates the highest version wins (ties keep the
    /// earlier entry, which GitHub returns most-recently-published first).
    nonisolated static func selectRelease(channel: UpdateChannel, from releases: [ReleaseInfo]) -> ReleaseInfo? {
        let candidates = releases.filter { r in
            guard !r.isDraft else { return false }
            switch channel {
            case .stable:     return !r.isPrerelease
            case .preRelease: return true
            }
        }
        guard var best = candidates.first else { return nil }
        for r in candidates.dropFirst() where isNewer(r.tag, than: best.tag) { best = r }
        return best
    }

    // MARK: - GitHub

    /// One release with everything needed to install it. `assetURL` is nil when a release has
    /// no `.zip` asset (e.g. a notes-only pre-release), in which case we fall back to opening
    /// the releases page.
    private struct FetchedRelease {
        let info: ReleaseInfo
        let notes: String
        let pageURL: URL
        let assetURL: URL?
    }

    private func fetchReleases() async -> [FetchedRelease]? {
        var req = URLRequest(url: Self.releasesListAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("AgentIsle", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        return arr.compactMap { json in
            guard let tag = json["tag_name"] as? String else { return nil }
            let assets = json["assets"] as? [[String: Any]] ?? []
            let assetURL = assets
                .first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init)
            let pageURL = (json["html_url"] as? String).flatMap(URL.init) ?? Self.releasesPage
            let info = ReleaseInfo(tag: tag,
                                   isPrerelease: (json["prerelease"] as? Bool) ?? false,
                                   isDraft: (json["draft"] as? Bool) ?? false)
            return FetchedRelease(info: info,
                                  notes: (json["body"] as? String) ?? "",
                                  pageURL: pageURL,
                                  assetURL: assetURL)
        }
    }

    // MARK: - Prompt

    private func promptForUpdate(_ release: FetchedRelease) {
        let alert = NSAlert()
        alert.messageText = "Update available: Agent Isle \(release.info.cleanVersion)"
        var info = "You're currently on \(currentVersion)."
        if release.info.isPrerelease { info += " This is a pre-release build." }
        alert.informativeText = info
        // Notes are Markdown: render them into a scrollable accessory view rather than
        // dumping the source into `informativeText`, which can't be styled or scrolled.
        alert.accessoryView = Self.notesView(release.notes)
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { await downloadAndInstall(release) }
        case .alertSecondButtonReturn:
            skippedVersion = release.info.tag
        default:
            break   // Later — we'll offer again on the next check
        }
    }

    /// Release notes as a scrollable, selectable text view sized to its content (capped, so a
    /// long changelog scrolls instead of growing the alert off-screen). Nil when there are none.
    private static func notesView(_ notes: String) -> NSView? {
        let rendered = ReleaseNotes.attributed(notes)
        guard rendered.length > 0 else { return nil }

        let outerWidth: CGFloat = 440
        let maxHeight: CGFloat = 260
        // Leave room for a legacy (always-visible) scroller so long notes never clip.
        let textWidth = outerWidth - 16

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: textWidth, height: maxHeight))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.containerSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = NSSize(width: textWidth, height: 0)
        text.maxSize = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        text.isAutomaticLinkDetectionEnabled = false   // links come from the Markdown itself
        text.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        text.textStorage?.setAttributedString(rendered)

        var contentHeight = maxHeight
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            contentHeight = ceil(layout.usedRect(for: container).height)
        }
        let height = min(max(contentHeight, 20), maxHeight)
        text.frame = NSRect(x: 0, y: 0, width: textWidth, height: max(contentHeight, height))

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: outerWidth, height: height))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = contentHeight > height
        scroll.autohidesScrollers = true
        scroll.documentView = text
        return scroll
    }

    // MARK: - Download & install

    private func downloadAndInstall(_ release: FetchedRelease) async {
        // No installable asset, or not a real `.app` bundle (e.g. a `swift run` dev process):
        // fall back to pointing the user at the releases page.
        guard isPackagedApp, let assetURL = release.assetURL else {
            if showInfo("Update available: Agent Isle \(release.info.cleanVersion)",
                        "Open the releases page to download it.",
                        confirm: "Open Releases Page") {
                NSWorkspace.shared.open(release.pageURL)
            }
            return
        }
        var workDir: URL?
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: assetURL)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.unpackFailed }

            let work = fm.temporaryDirectory
                .appendingPathComponent("agent-isle-update-\(UUID().uuidString)")
            workDir = work
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zipURL = work.appendingPathComponent("Agent-Isle.zip")
            try fm.moveItem(at: tmp, to: zipURL)

            let unzipDir = work.appendingPathComponent("app")
            try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)
            guard await Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, unzipDir.path]) == 0,
                  let newApp = Self.firstApp(in: unzipDir)
            else { throw UpdateError.unpackFailed }

            // Refuse unsigned / differently-team-signed bundles. A compromised GitHub
            // release must not auto-install: the candidate has to satisfy the pinned
            // Developer ID Team ID, not merely pass a structural codesign verify.
            try await Self.verifyUpdateCandidate(newApp)

            // Hand the swap+relaunch to a detached helper: it waits for us to quit,
            // replaces the bundle (with rollback on failure), then reopens the app.
            // The helper reads from workDir after we exit, so we don't remove it here.
            try Self.installAndRelaunch(newApp: newApp, dest: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            if let workDir { try? fm.removeItem(at: workDir) }
            NSLog("Updater install failed: \(error)")
            let choseOpen = showInfo("Couldn't install the update automatically",
                                     "You can download it manually from the releases page.",
                                     confirm: "Open Releases Page")
            if choseOpen { NSWorkspace.shared.open(release.pageURL) }
        }
    }

    /// Run a tool and return its exit status, off the main actor.
    nonisolated private static func run(_ path: String, _ args: [String]) async -> Int32 {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                do { try p.run(); p.waitUntilExit(); cont.resume(returning: p.terminationStatus) }
                catch { cont.resume(returning: -1) }
            }
        }
    }

    nonisolated private static func firstApp(in dir: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
    }

    // MARK: - Signature gate

    /// Verify `candidate` is signed by the official Developer ID team.
    /// `--verify --strict` is not enough: it accepts ad-hoc signatures. The `-R=`
    /// requirement is what rejects unsigned, ad-hoc, and other-team bundles.
    nonisolated static func verifyUpdateCandidate(_ candidate: URL) async throws {
        let status = await run("/usr/bin/codesign", [
            "--verify", "--strict",
            "-R=\(codesignRequirement)",
            candidate.path,
        ])
        guard status == 0 else { throw UpdateError.invalidSignature }
    }

    /// Spawn a detached shell helper that waits for this process to exit, swaps the
    /// bundle in place (restoring the backup if the copy fails), then relaunches.
    ///
    /// Quarantine is only cleared after the candidate already passed
    /// `verifyUpdateCandidate` — never as a substitute for signature checks.
    /// The helper re-runs the same codesign requirement immediately before `ditto`
    /// so a casual same-user swap of the temp bundle after we quit does not land.
    nonisolated private static func installAndRelaunch(newApp: URL, dest: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        APP_PID=\(pid)
        SRC=\(shellQuote(newApp.path))
        DEST=\(shellQuote(dest.path))
        REQ=\(shellQuote(codesignRequirement))
        BACKUP="${DEST}.old-$$"
        while /bin/kill -0 "$APP_PID" 2>/dev/null; do /bin/sleep 0.2; done
        # Re-check after this process has exited: the Swift-side verify is otherwise
        # a TOCTOU against anything that can write the temp bundle.
        if ! /usr/bin/codesign --verify --strict -R="$REQ" "$SRC"; then
          /usr/bin/open "$DEST"
          exit 1
        fi
        # Only swap if we can safely move the current bundle aside first; otherwise
        # leave it untouched (a failed update must never delete the installed app).
        if /bin/mv "$DEST" "$BACKUP"; then
          if /usr/bin/ditto "$SRC" "$DEST"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
            /bin/rm -rf "$BACKUP"
          else
            /bin/rm -rf "$DEST"; /bin/mv "$BACKUP" "$DEST"
          fi
        fi
        /usr/bin/open "$DEST"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-isle-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try p.run()   // detached — keeps running after we terminate
    }

    /// Single-quote a path for safe interpolation into the helper script.
    nonisolated private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Version compare

    /// True if `remote` is a strictly higher version than `local` (tolerant of a
    /// leading "v" and non-numeric suffixes).
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
             .split(separator: ".")
             .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Alerts

    @discardableResult
    private func showInfo(_ title: String, _ body: String, confirm: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: confirm ?? "OK")
        if confirm != nil { alert.addButton(withTitle: "Cancel") }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum UpdateError: Error, Equatable {
    case unpackFailed
    case invalidSignature
}
