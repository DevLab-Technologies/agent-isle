import Foundation

/// Minimal shared HTTP/1.1 request framing over a raw socket: decides when a buffered
/// read becomes one complete request, and splits a complete request into its request
/// line and body. Used by both `EventServer` (hook events, loopback-only) and
/// `RemoteActionServer` (mobile approvals, LAN/Tailscale) since they speak the same
/// wire protocol.
enum HTTPFraming {
    enum RequestLength: Equatable {
        case incompleteHeaders
        case complete(Int)
        case invalid
    }

    static let headerTerminator = Data("\r\n\r\n".utf8)

    static func requestLength(in data: Data, maxRequestSize: Int) -> RequestLength {
        guard let range = data.range(of: headerTerminator) else { return .incompleteHeaders }
        guard let headers = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
        let headerLength = data.distance(from: data.startIndex, to: range.upperBound)
        // Bound before adding: Content-Length of Int.max + headerLength traps and kills
        // the process, taking every parked permission/question with it.
        guard let contentLength, contentLength >= 0,
              contentLength <= maxRequestSize - headerLength else { return .invalid }
        return .complete(headerLength + contentLength)
    }

    /// The request line's method and path, e.g. `("GET", "/r/abc123/state")`.
    static func requestLine(in data: Data) -> (method: String, path: String)? {
        guard let range = data.range(of: headerTerminator),
              let headers = String(data: data[..<range.lowerBound], encoding: .utf8),
              let firstLine = headers.components(separatedBy: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// The body of a complete request (everything after the header terminator).
    static func body(of data: Data) -> Data {
        guard let range = data.range(of: headerTerminator) else { return Data() }
        return data[range.upperBound...]
    }
}
