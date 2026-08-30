import XCTest
@testable import AgentIsle

final class HTTPFramingTests: XCTestCase {

    private func httpRequest(_ requestLine: String, headers: [String] = [], body: String = "") -> Data {
        var lines = [requestLine] + headers
        if !body.isEmpty && !headers.contains(where: { $0.lowercased().hasPrefix("content-length:") }) {
            lines.append("Content-Length: \(body.utf8.count)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
    }

    func testRequestLineParsesMethodAndPath() {
        let data = httpRequest("GET /r/abc123/state HTTP/1.1", headers: ["Host: 1.2.3.4"])
        let line = HTTPFraming.requestLine(in: data)
        XCTAssertEqual(line?.method, "GET")
        XCTAssertEqual(line?.path, "/r/abc123/state")
    }

    func testRequestLineNilWithoutHeaderTerminator() {
        XCTAssertNil(HTTPFraming.requestLine(in: Data("GET /r/abc HTTP/1.1\r\n".utf8)))
    }

    func testBodyExtractsContentAfterHeaders() {
        let data = httpRequest("POST /r/abc123/decision HTTP/1.1", body: #"{"decision":"allow"}"#)
        XCTAssertEqual(HTTPFraming.body(of: data), Data(#"{"decision":"allow"}"#.utf8))
    }

    func testBodyEmptyWithoutHeaderTerminator() {
        XCTAssertEqual(HTTPFraming.body(of: Data("incomplete".utf8)), Data())
    }

    // MARK: - requireContentLength: false (RemoteActionServer's GETs, no request body)

    func testMissingContentLengthInvalidByDefault() {
        let data = httpRequest("GET /r/abc123/state HTTP/1.1", headers: ["Host: 1.2.3.4"])
        XCTAssertEqual(HTTPFraming.requestLength(in: data, maxRequestSize: 4096), .invalid)
    }

    func testMissingContentLengthTreatedAsZeroWhenNotRequired() {
        let data = httpRequest("GET /r/abc123/state HTTP/1.1", headers: ["Host: 1.2.3.4"])
        XCTAssertEqual(HTTPFraming.requestLength(in: data, maxRequestSize: 4096, requireContentLength: false),
                      .complete(data.count))
    }

    func testExplicitContentLengthStillHonoredWhenNotRequired() {
        let body = #"{"decision":"allow"}"#
        let data = httpRequest("POST /r/abc123/decision HTTP/1.1", body: body)
        XCTAssertEqual(HTTPFraming.requestLength(in: data, maxRequestSize: 4096, requireContentLength: false),
                      .complete(data.count))
    }
}
