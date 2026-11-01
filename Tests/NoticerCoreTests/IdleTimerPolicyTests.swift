import XCTest
@testable import NoticerCore

final class IdleTimerPolicyTests: XCTestCase {
    func testScreenStaysAwakeWhileAnyReasonRemains() {
        XCTAssertTrue(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: true, demoSession: false, sceneActive: true))
        XCTAssertTrue(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: false, demoSession: true, sceneActive: true))
        XCTAssertTrue(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: true, demoSession: true, sceneActive: true))
    }

    func testScreenSleepsOnlyWhenNoReasonWantsIt() {
        XCTAssertFalse(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: false, demoSession: false, sceneActive: true))
    }

    func testBackgroundDropsTheScreenEvenIfASessionWantsIt() {
        XCTAssertFalse(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: true, demoSession: true, sceneActive: false))
        XCTAssertFalse(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: true, demoSession: false, sceneActive: false))
        XCTAssertFalse(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: false, demoSession: true, sceneActive: false))
        XCTAssertFalse(IdleTimerPolicy.disableIdleTimer(keepsScreenOn: false, demoSession: false, sceneActive: false))
    }
}
