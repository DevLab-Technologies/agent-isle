import Foundation

/// Detects addresses this Mac is reachable at, for `RemoteActionServer`'s QR links: the
/// LAN address (Wi-Fi/Ethernet) and, if Tailscale is running, its address — Tailscale
/// assigns from the CGNAT range `100.64.0.0/10`, seen on a `utun*` interface once
/// connected. No Tailscale SDK involved: it just shows up as another IP on the host.
enum NetworkInterfaces {
    struct Address {
        enum Kind { case lan, tailscale }
        let kind: Kind
        let host: String
    }

    /// One address per kind (LAN and/or Tailscale), first match wins if an interface
    /// repeats. Empty when neither is reachable (e.g. no active network).
    static func reachableAddresses() -> [Address] {
        var addrs: [Address] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &hostBuf, socklen_t(hostBuf.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: hostBuf)
            let name = String(cString: current.pointee.ifa_name)

            if isTailscaleAddress(ip), !addrs.contains(where: { $0.kind == .tailscale }) {
                addrs.append(Address(kind: .tailscale, host: ip))
            } else if name.hasPrefix("en"), !addrs.contains(where: { $0.kind == .lan }) {
                addrs.append(Address(kind: .lan, host: ip))
            }
        }
        return addrs
    }

    private static func isTailscaleAddress(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1])
    }
}
