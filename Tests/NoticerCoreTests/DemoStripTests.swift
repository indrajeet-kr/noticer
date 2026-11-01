import Foundation
import XCTest
import NoticerCore

/// Demo strip: the pure-observer mapping from engine events to big plain
/// words, plus the bounded buffer. Public API only, so it runs on Linux.
final class DemoStripTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func needs() -> [Need] {
        [
            Need(id: "couch-water", authorText: "Her water is empty", cueWording: "Her water's empty.", priority: 0),
            Need(
                id: "clean-floor-toys",
                authorText: "Clean the floor toys are internationalization and more",
                cueWording: "Toys are on the floor.",
                priority: 1
            ),
        ]
    }

    private func event(_ kind: EngineEventKind, needID: String? = nil, detail: String? = nil, at: Date? = nil) -> EngineEvent {
        EngineEvent(kind: kind, needID: needID, at: at ?? start, detail: detail)
    }

    private func mapped(_ event: EngineEvent) -> (String, DemoStripItem.Style, Date?)? {
        DemoStripMapper.item(for: event, needs: needs(), headStartSeconds: { _ in 10 })
    }

    /// Every `EngineEventKind` today. `EngineEventKind` is not `CaseIterable`
    /// and the demo change must not touch it, so the sweep lists kinds here.
    private static let allKinds: [EngineEventKind] = [
        .needLatched, .latchRejected, .cueFired, .cueDeferredHandsBusy, .cueDeferredRateLimit,
        .caughtHimself, .resolvedByPartner, .closedUnknown, .falseCueDismissed,
        .masteryRetired, .masteryUnretired, .needReset, .visitorPaused, .visitorResumed,
        .headStartExtended, .headStartExtensionDenied, .recheckRequested, .actionRejected,
        .assessmentDropped, .staleReplyDropped, .callBudgetExhausted, .sessionEnded,
        .retiredMiss, .callIssued, .stillOpen, .skip,
    ]

    func testMappingTable() throws {
        let latched = event(.needLatched, needID: "couch-water")
        let noticed = try XCTUnwrap(mapped(latched))
        XCTAssertEqual(noticed.0, "Noticed: Her water is empty")
        XCTAssertEqual(noticed.1, .noticed)
        XCTAssertNil(noticed.2)

        let followUp = try XCTUnwrap(DemoStripMapper.headStartFollowUp(for: latched, headStartSeconds: { _ in 10 }, now: start))
        XCTAssertEqual(followUp.0, "Head start: 10s for you")
        XCTAssertEqual(followUp.1, .headStart)
        XCTAssertEqual(followUp.2, start.addingTimeInterval(10))

        XCTAssertEqual(mapped(event(.stillOpen, detail: "out-of-view"))?.0, "Still open · out of view")
        XCTAssertEqual(mapped(event(.stillOpen, detail: "out-of-view"))?.1, .neutral)

        let shared = try XCTUnwrap(mapped(event(.caughtHimself, needID: "couch-water", detail: "shared-finish")))
        XCTAssertEqual(shared.0, "You finished it. Nice teamwork.")
        XCTAssertEqual(shared.1, .outcomeWin)

        for detail in ["after-cue", "before-cue", "recent-intervention", nil] {
            let solo = try XCTUnwrap(mapped(event(.caughtHimself, needID: "couch-water", detail: detail)))
            XCTAssertEqual(solo.0, "You got it", "detail \(detail ?? "nil")")
            XCTAssertEqual(solo.1, .outcomeWin)
        }

        let partner = try XCTUnwrap(mapped(event(.resolvedByPartner, needID: "couch-water")))
        XCTAssertEqual(partner.0, "She handled it")
        XCTAssertEqual(partner.1, .outcomeOther)

        let unclear = try XCTUnwrap(mapped(event(.closedUnknown, needID: "couch-water")))
        XCTAssertEqual(unclear.0, "Handled · unclear who")
        XCTAssertEqual(unclear.1, .outcomeOther)

        let busy = try XCTUnwrap(mapped(event(.cueDeferredHandsBusy, needID: "couch-water")))
        XCTAssertEqual(busy.0, "Holding the whisper · hands busy")
        XCTAssertEqual(busy.1, .neutral)

        let extended = try XCTUnwrap(mapped(event(.headStartExtended, needID: "couch-water")))
        XCTAssertEqual(extended.0, "More time for you")
        XCTAssertEqual(extended.1, .neutral)
    }

    func testHiddenKindsReturnNil() {
        XCTAssertNil(mapped(event(.callIssued)))
        XCTAssertNil(mapped(event(.skip, detail: "idle-bucket")))
        XCTAssertNil(mapped(event(.staleReplyDropped)))
        XCTAssertNil(mapped(event(.actionRejected, detail: "unrelated-wearer-action")))
        XCTAssertNil(mapped(event(.stillOpen, detail: "no-change")))
        XCTAssertNil(mapped(event(.stillOpen, detail: "unclear")))
        XCTAssertNil(mapped(event(.stillOpen)))
        XCTAssertNil(mapped(event(.cueFired, needID: "couch-water", detail: "whisper")))
        XCTAssertNil(DemoStripMapper.headStartFollowUp(for: event(.cueFired), headStartSeconds: { _ in 10 }))
        XCTAssertNil(DemoStripMapper.headStartFollowUp(for: event(.needLatched), headStartSeconds: { _ in 10 }))
    }

    func testHeadStartCountdownAnchoredToNowNotEventTime() throws {
        // Replay stamps the latch on a clock that can lag the wall clock
        // the strip renders against. The countdown must start from drain
        // time, not the stale event stamp.
        let stale = event(.needLatched, needID: "couch-water", at: start)
        let followUp = try XCTUnwrap(
            DemoStripMapper.headStartFollowUp(for: stale, headStartSeconds: { _ in 10 }, now: start.addingTimeInterval(30))
        )
        XCTAssertEqual(followUp.0, "Head start: 10s for you")
        XCTAssertEqual(followUp.2, start.addingTimeInterval(40))
    }

    func testShortTitleUsesWordsNotIDs() {
        XCTAssertEqual(DemoStripMapper.shortTitle(for: "couch-water", needs: needs()), "Her water is empty")
        XCTAssertEqual(
            DemoStripMapper.shortTitle(for: "clean-floor-toys", needs: needs()),
            "Clean the floor toys are…"
        )
        XCTAssertEqual(DemoStripMapper.shortTitle(for: "missing-need", needs: needs()), "a need")
        XCTAssertEqual(DemoStripMapper.shortTitle(for: nil, needs: needs()), "a need")
        let exact = String(repeating: "a", count: 40)
        let exactNeed = Need(id: "exact", authorText: exact, cueWording: "", priority: 0)
        XCTAssertEqual(DemoStripMapper.shortTitle(for: "exact", needs: [exactNeed]), exact)
    }

    func testBufferBounded() {
        var strip = DemoStripBuffer()
        strip.reset(sessionStart: start)
        for i in 0..<100 {
            strip.append("row \(i)", style: .neutral, at: start.addingTimeInterval(TimeInterval(i)))
        }
        XCTAssertEqual(strip.items.count, 20)
        let visible = strip.visibleItems()
        XCTAssertEqual(visible.count, 5)
        XCTAssertEqual(visible.map(\.text), ["row 95", "row 96", "row 97", "row 98", "row 99"])
        XCTAssertEqual(visible.last?.text, strip.items.last?.text)
        let ids = strip.items.map(\.id)
        XCTAssertEqual(ids, Array(80..<100))
        XCTAssertEqual(ids, ids.sorted())
    }

    func testRelativeTimeFormat() {
        var strip = DemoStripBuffer()
        strip.reset(sessionStart: start)
        func item(at date: Date) -> DemoStripItem {
            DemoStripItem(id: 0, at: date, text: "x", style: .neutral)
        }
        XCTAssertEqual(strip.relativeTime(item(at: start)), "+0.0s")
        XCTAssertEqual(strip.relativeTime(item(at: start.addingTimeInterval(12.44))), "+12.4s")
        XCTAssertEqual(strip.relativeTime(item(at: start.addingTimeInterval(65))), "+1:05")
        XCTAssertEqual(strip.relativeTime(item(at: start.addingTimeInterval(-3))), "+0.0s")
        XCTAssertEqual(DemoStripBuffer().relativeTime(item(at: start)), "+0.0s")
    }

    func testLatencyChipParsing() {
        XCTAssertEqual(
            DemoStripMapper.latencyChip(fromTimingLine: "call=call-4 purpose=latch queue=0ms model=2694ms apply=0.7ms bytes=44208"),
            "Muse Spark · 2.7s"
        )
        XCTAssertEqual(
            DemoStripMapper.latencyChip(fromTimingLine: "call=call-9 purpose=heartbeat queue=12ms model=2604ms apply=0.7ms bytes=44208"),
            "Muse Spark · 2.6s"
        )
        XCTAssertNil(DemoStripMapper.latencyChip(fromTimingLine: "calls/min=6 open=0"))
        XCTAssertNil(DemoStripMapper.latencyChip(fromTimingLine: "need=x visible→latch=6.7s latch→cue=2.0s cue→speech=371ms"))
        XCTAssertNil(DemoStripMapper.latencyChip(fromTimingLine: ""))
        XCTAssertNil(DemoStripMapper.latencyChip(fromTimingLine: "call=call-1 purpose=latch model=abcms"))
    }

    func testWhisperCaptionIsExactSpokenText() {
        let spoken = "Toys everywhere, quick tidy?"
        let caption = DemoStripMapper.whisperCaption(spoken)
        XCTAssertEqual(caption, "Whispered: “Toys everywhere, quick tidy?”")
        let prefix = "Whispered: “"
        XCTAssertTrue(caption.hasPrefix(prefix))
        XCTAssertTrue(caption.hasSuffix("”"))
        let inner = String(caption.dropFirst(prefix.count).dropLast("”".count))
        XCTAssertEqual(inner, spoken)
        XCTAssertEqual(Array(inner.utf8), Array(spoken.utf8))
    }

    func testAllFixedStringsPassWordRules() {
        var corpus = [DemoStripMapper.firstFrame, DemoStripMapper.listening]
        for kind in Self.allKinds {
            for detail in [nil, "out-of-view", "no-change", "shared-finish", "after-cue", "whisper", "idle-bucket"] {
                if let mapped = mapped(event(kind, needID: "couch-water", detail: detail)) {
                    corpus.append(mapped.0)
                }
            }
        }
        if let followUp = DemoStripMapper.headStartFollowUp(for: event(.needLatched, needID: "couch-water"), headStartSeconds: { _ in 10 }) {
            corpus.append(followUp.0)
        }
        corpus.append(DemoStripMapper.whisperCaption("Toys everywhere, quick tidy?"))
        if let chip = DemoStripMapper.latencyChip(fromTimingLine: "call=call-4 purpose=latch queue=0ms model=2694ms apply=0.7ms bytes=44208") {
            corpus.append(chip)
        }
        XCTAssertFalse(corpus.isEmpty)
        for text in corpus {
            XCTAssertTrue(DemoStripMapper.passesWordRules(text), text)
        }
        XCTAssertFalse(DemoStripMapper.passesWordRules("Watching quietly"))
    }

    func testNoSecretsOrJSON() {
        var corpus: [String] = [DemoStripMapper.firstFrame, DemoStripMapper.listening]
        for kind in Self.allKinds {
            for detail in [nil, "out-of-view", "no-change", "shared-finish", "after-cue", "whisper", "idle-bucket"] {
                if let mapped = mapped(event(kind, needID: "couch-water", detail: detail)) {
                    corpus.append(mapped.0)
                }
            }
        }
        corpus.append(DemoStripMapper.whisperCaption("Toys everywhere, quick tidy?"))
        if let chip = DemoStripMapper.latencyChip(fromTimingLine: "call=call-4 purpose=latch queue=0ms model=2694ms apply=0.7ms bytes=44208") {
            corpus.append(chip)
        }
        let banned = ["{", "}", "key=", "call-", "kf-", "need_id"] + ToolName.allCases.map(\.rawValue)
        for text in corpus {
            for token in banned {
                XCTAssertFalse(text.contains(token), "\(text) contains \(token)")
            }
        }
    }

    func testReplayOfSession3Sequence() {
        var strip = DemoStripBuffer()
        strip.reset(sessionStart: start)
        let needs = needs()
        let headStart: (String) -> TimeInterval? = { _ in 10 }
        let latched = event(.needLatched, needID: "clean-floor-toys")
        for row in [
            DemoStripMapper.item(for: latched, needs: needs, headStartSeconds: headStart),
            DemoStripMapper.headStartFollowUp(for: latched, headStartSeconds: headStart),
            DemoStripMapper.item(for: event(.stillOpen, needID: "clean-floor-toys", detail: "out-of-view"), needs: needs, headStartSeconds: headStart),
            DemoStripMapper.item(for: event(.resolvedByPartner, needID: "clean-floor-toys"), needs: needs, headStartSeconds: headStart),
        ] {
            guard let row else {
                XCTFail("expected a strip row")
                return
            }
            strip.append(row.0, style: row.1, at: start, countdownEndsAt: row.2)
        }
        XCTAssertEqual(
            strip.items.map(\.text),
            [
                "Noticed: Clean the floor toys are…",
                "Head start: 10s for you",
                "Still open · out of view",
                "She handled it",
            ]
        )
        XCTAssertEqual(
            DemoStripMapper.latencyChip(fromTimingLine: "call=call-9 purpose=heartbeat queue=12ms model=2604ms apply=0.7ms bytes=44208"),
            "Muse Spark · 2.6s"
        )
    }
}
