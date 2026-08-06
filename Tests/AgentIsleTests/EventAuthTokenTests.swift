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
}
