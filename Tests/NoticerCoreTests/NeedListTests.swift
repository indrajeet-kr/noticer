import XCTest
@testable import NoticerCore

final class NeedListTests: EngineTestCase {
    func testMomCanAuthorUpToSixNeeds() throws {
        let needs = (0..<SessionLimits.maxAuthoredNeeds).map {
            Self.need(id: "need-\($0)", priority: $0)
        }
        let listed = try NeedEngine(clock: clock, needs: needs)
        XCTAssertEqual(listed.needs.map(\.id), needs.map(\.id))
    }

    func testASeventhNeedIsRefused() {
        let needs = (0..<7).map { Self.need(id: "need-\($0)", priority: $0) }
        XCTAssertThrowsError(try NeedEngine(clock: clock, needs: needs)) { error in
            XCTAssertEqual(error as? NeedListError, .exceedsAuthoredLimit(6))
        }
    }

    func testDuplicateNeedIDsAreRefused() {
        let duplicate = Self.need(id: "take-baby", priority: 3)
        XCTAssertThrowsError(try NeedEngine(clock: clock, needs: [Self.takeBaby(), duplicate])) { error in
            XCTAssertEqual(error as? NeedListError, .duplicateIdentifier("take-baby"))
        }
    }

    func testMomCanResetANeedBackToCoaching() throws {
        let retired = MasteryState(score: 0.578125, consecutiveSelfNotices: 3, consecutiveMisses: 0)
        XCTAssertEqual(retired.phase, .retired)
        try engine.setNeeds([Self.takeBaby(mastery: retired)])
        try engine.resetNeed("take-baby")
        let mastery = mastery(of: "take-baby")
        XCTAssertEqual(mastery, .initial)
        XCTAssertEqual(mastery.phase, .coaching)
        XCTAssertEqual(events(.needReset).map(\.needID), ["take-baby"])
    }

    func testResetOfAnUnknownNeedThrows() {
        XCTAssertThrowsError(try engine.resetNeed("not-a-need")) { error in
            XCTAssertEqual(error as? NeedListError, .unknownNeed("not-a-need"))
        }
    }
}
