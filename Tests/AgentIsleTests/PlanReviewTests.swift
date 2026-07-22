import XCTest
@testable import AgentIsle

/// The Plan Review pieces: the Markdown block parser feeding `PlanReviewCard`, the plan's
/// compact summary, and the store transitions when a plan is approved or sent back with
/// feedback (the same reply wiring the parked hook uses, exercised without a live socket).
@MainActor
final class PlanReviewTests: XCTestCase {

    // MARK: - Markdown parsing

    func testParsesHeadingsListsCodeAndQuotes() {
        let md = """
        # Title
        A paragraph of text.

        ## Steps
        1. First
        2. Second

        - a bullet
        * another

        > a quote

        ```
        let x = 1
        ```
        """
        let blocks = MarkdownBlock.parse(md)
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .paragraph("A paragraph of text."),
            .heading(level: 2, text: "Steps"),
            .ordered(number: 1, text: "First"),
            .ordered(number: 2, text: "Second"),
            .bullet("a bullet"),
            .bullet("another"),
            .quote("a quote"),
            .code("let x = 1"),
        ])
    }

    func testConsecutiveTextLinesFoldIntoOneParagraph() {
        let blocks = MarkdownBlock.parse("line one\nline two")
        XCTAssertEqual(blocks, [.paragraph("line one line two")])
    }

    func testUnterminatedCodeFenceStillEmitsCode() {
        let blocks = MarkdownBlock.parse("```\nnot closed\nmore")
        XCTAssertEqual(blocks, [.code("not closed\nmore")])
    }

    // MARK: - Summary

    func testSummaryUsesFirstHeadingStrippedOfMarks() {
        let plan = AgentPlan(markdown: "## **Refactor** the `auth` layer\n\nbody")
        XCTAssertEqual(plan.summary, "Refactor the auth layer")
    }

    func testSummaryFallsBackWhenEmpty() {
        XCTAssertEqual(AgentPlan(markdown: "   \n\n").summary, "Plan ready for review")
    }

    // MARK: - Store transitions

    private func planSession() -> (SessionStore, UUID) {
        let store = SessionStore()
        let id = UUID()
        store.upsert(AgentSession(id: id, agent: .claude, title: "t", terminal: "iTerm",
                                  lastMessage: "", status: .planning,
                                  plan: AgentPlan(markdown: "## Plan\n- do it")))
        return (store, id)
    }

    func testApproveClearsPlanAndResumesWorking() {
        let (store, id) = planSession()
        store.approvePlan(sessionID: id)
        let s = store.sessions.first { $0.id == id }
        XCTAssertNil(s?.plan)
        XCTAssertEqual(s?.status, .working)
        XCTAssertEqual(s?.lastMessage, "Plan approved")
    }

    func testFeedbackClearsPlanAndRecordsMessage() {
        let (store, id) = planSession()
        store.sendPlanFeedback(sessionID: id, feedback: "use a queue instead")
        let s = store.sessions.first { $0.id == id }
        XCTAssertNil(s?.plan)
        XCTAssertEqual(s?.status, .working)
        XCTAssertEqual(s?.lastMessage, "Plan feedback: use a queue instead")
    }

    func testBlankFeedbackIsTreatedAsApproval() {
        let (store, id) = planSession()
        store.sendPlanFeedback(sessionID: id, feedback: "   ")
        XCTAssertEqual(store.sessions.first { $0.id == id }?.lastMessage, "Plan approved")
    }

    func testPlanningCountsTowardAttention() {
        let (store, _) = planSession()
        XCTAssertEqual(store.attentionCount, 1)
    }
}
