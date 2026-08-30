import SwiftUI

/// "Approve from phone" — mints a token for this session's current prompt and shows a
/// QR code (LAN and/or Tailscale) a phone can scan to open the same decision remotely.
struct RemoteApprovalButton: View {
    let sessionID: UUID

    @State private var link: RemoteAccessLink?
    @State private var showPopover = false
    @State private var failed = false

    var body: some View {
        Button {
            link = RemoteActionServer.shared.issueLink(sessionID: sessionID)
            failed = link == nil
            showPopover = true
        } label: {
            Image(systemName: "qrcode")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help("Approve from phone")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            if let link {
                RemoteApprovalPopover(link: link)
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
            Text("Scan to approve from your phone")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 212)
    }
}
