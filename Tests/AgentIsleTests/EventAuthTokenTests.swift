import XCTest
@testable import AgentIsle

final class EventAuthTokenTests: XCTestCase {

    func testConstantTimeEqualMatchesOnlyIdenticalStrings() {
        XCTAssertTrue(EventAuthToken.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(EventAuthToken.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(EventAuthToken.constantTimeEqual("abc", "ab"))
        XCTAssertFalse(EventAuthToken.constantTimeEqual("abc", "abcd"))
    }

    func testHeaderNameIsStableForHooks() {
        XCTAssertEqual(EventAuthToken.headerName, "X-Agent-Isle-Token")
    }

    func testWriteForcesOwnerOnlyDirAndFile() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("agent-isle-token-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o755,
        ])
        defer { try? fm.removeItem(at: dir) }

        try EventAuthToken.write("deadbeef", directory: dir)

        let dirMode = try posixMode(of: dir)
        XCTAssertEqual(dirMode, 0o700, "existing 0755 dir must be narrowed to 0700")

        let file = dir.appendingPathComponent("token")
        let fileMode = try posixMode(of: file)
        XCTAssertEqual(fileMode, 0o600)

        let body = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(body, "deadbeef")
    }

    private func posixMode(of url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let raw = attrs[.posixPermissions] as? NSNumber
        return (raw?.uint16Value ?? 0) & 0o777
    }
}
