import SwiftUI

/// Global "Connect phone" control in the island's header — mints (or reuses) a standing
/// pairing link covering every session, so the phone can act on whichever
/// permission/question/plan comes up while it's paired, not just one prompt.
struct RemoteApprovalButton: View {
    @State private var link: RemoteAccessLink?
    @State private var showPopover = false
    @State private var failed = false
    @State private var connected = false

    var body: some View {
        Button {
            link = RemoteActionServer.shared.currentLink()
            failed = link == nil
            connected = link != nil
            showPopover = true
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
            if let link {
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
            if selected < link.endpoints.count,
               let image = QRCode.image(for: link.endpoints[selected].url.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 180, height: 180)
            }
            Text(reachabilityCaption)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
