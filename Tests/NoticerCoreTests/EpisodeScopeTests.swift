import XCTest
@testable import NoticerCore

/// Latch episodes are UUIDs: two fresh engines never issue the same id,
/// so a phone match on episode id can't collide across sessions.
final class EpisodeScopeTests: EngineTestCase {
    private func latchUrgent() throws -> String {
        var urgent = Self.takeBaby()
        urgent.isUrgent = true
        try engine.setNeeds([urgent, Self.refillWater()])
        see([mom()])
        let call = try XCTUnwrap(engine.pendingModelCall)
        engine.handle(callID: call.id, verdict: latchVerdict("take-baby"))
        engine.tick()
        return try XCTUnwrap(events(.cueFired).first?.episodeID)
    }

    func testEpisodeIDsNeverCollideAcrossEngines() throws {
        let episodeA = try latchUrgent()
        XCTAssertNotNil(UUID(uuidString: episodeA))

        engine = try NeedEngine(clock: clock, needs: [Self.takeBaby(), Self.refillWater()])
        let episodeB = try latchUrgent()

        XCTAssertNotEqual(episodeA, episodeB)
    }
}
