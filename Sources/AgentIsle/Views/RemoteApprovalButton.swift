import SwiftUI
import AppKit

/// Global "Connect phone" control in the island's header — mints (or reuses) a standing
/// pairing link covering every session, so the phone can act on whichever
/// permission/question/plan comes up while it's paired, not just one prompt.
struct RemoteApprovalButton: View {
    @State private var link: RemoteAccessLink?
    @State private var showPopover = false
    @State private var failed = false
    @State private var connected = false
    @State private var loading = false

    var body: some View {
        Button {
            // Show the popover immediately with a spinner rather than computing the link
            // synchronously in this tap — starting the listener (and, the first time,
            // fetching a Tailscale HTTPS cert) can take a real, visible moment, and doing
            // that work before the popover ever appears is what produced the stuck/blank
            // icon: the button had nothing to show yet.
            link = nil
            failed = false
            loading = true
            showPopover = true
            Task {
                let result = await RemoteActionServer.shared.currentLink()
                link = result
                failed = result == nil
                connected = result != nil
                loading = false
            }
        } label: {
            Image(systemName: connected ? "qrcode.viewfinder" : "qrcode")
                .font(.system(size: 11))
                .foregroundStyle(connected ? SessionStatus.working.color : .white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Connect a phone to approve from anywhere")
        .fixedSize()
        .onAppear { connected = RemoteActionServer.shared.isConnected }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 180, height: 180)
                    .padding(16)
            } else if let link {
                RemoteApprovalPopover(link: link) {
                    RemoteActionServer.shared.disconnect()
                    connected = false
                    showPopover = false
                }
            } else if failed {
                Text("Couldn't start remote approval — no network reachable, or the port is in use.")
                    .font(.system(size: 11))
                    .frame(width: 180)
                    .padding(16)
            }
        }
    }
}

private struct RemoteApprovalPopover: View {
    let link: RemoteAccessLink
    let onDisconnect: () -> Void
    @State private var selected = 0
    @State private var copied = false

    private var currentURL: URL? {
        selected < link.endpoints.count ? link.endpoints[selected].url : nil
    }

    var body: some View {
        VStack(spacing: 10) {
            if link.endpoints.count > 1 {
                Picker("", selection: $selected) {
                    ForEach(Array(link.endpoints.enumerated()), id: \.offset) { idx, endpoint in
                        Text(endpoint.kind == .lan ? "Same Network" : "Tailscale").tag(idx)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let url = currentURL, let image = QRCode.image(for: url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
            }
            Text(reachabilityCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Button {
                    copyLink()
                } label: {
                    Label(copied ? "Copied!" : "Copy Link", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                ShareLinkButton(url: currentURL)
                    .controlSize(.small)
            }
            Button("Disconnect", action: onDisconnect)
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.deny)
        }
        .padding(16)
        .frame(width: 212)
        // Prefer Tailscale by default when both are available: it's the one that still
        // works once the phone (or the Mac) leaves the house, which is the harder and
        // more common case people reach for this for.
        .onAppear {
            if let tailscaleIdx = link.endpoints.firstIndex(where: { $0.kind == .tailscale }) {
                selected = tailscaleIdx
            }
        }
    }

    private func copyLink() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private var reachabilityCaption: String {
        guard selected < link.endpoints.count else { return "" }
        switch link.endpoints[selected].kind {
        case .lan:
            return "Works only while your phone is on this same Wi-Fi/network."
        case .tailscale:
            return "Works from anywhere — as long as Tailscale is on for both devices."
        }
    }
}

/// Presents macOS's native share sheet (Messages, AirDrop, Mail, etc.) for the link, so it
/// can reach the phone without scanning a QR code at all.
private struct ShareLinkButton: View {
    let url: URL?

    var body: some View {
        Button {
            guard let url, let anchor = Self.anchorView() else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } label: {
            Label("Share…", systemImage: "square.and.arrow.up")
                .font(.system(size: 11))
        }
        .buttonStyle(.bordered)
        .disabled(url == nil)
    }

    /// Any visible window's content view works as the picker's anchor — this popover
    /// isn't hosted in a normal app window, so there's no single "right" one to reach for.
    private static func anchorView() -> NSView? {
        NSApp.windows.first(where: { $0.isVisible })?.contentView
    }
}
