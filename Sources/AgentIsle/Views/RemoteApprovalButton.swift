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
            Text("Scan to approve any session from your phone")
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
    }
}
