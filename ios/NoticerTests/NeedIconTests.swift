import NoticerCore
import XCTest

/// Need card icons: keyword mapping plus the heart fallback.
final class NeedIconTests: XCTestCase {
    func testKeywordMapping() {
        XCTAssertEqual(NeedIcon.symbol(for: "take the baby"), "figure.and.child.holdinghands")
        XCTAssertEqual(NeedIcon.symbol(for: "hold her for a bit"), "figure.and.child.holdinghands")
        XCTAssertEqual(NeedIcon.symbol(for: "nursing, no water"), "drop")
        XCTAssertEqual(NeedIcon.symbol(for: "refill my drink"), "drop")
        XCTAssertEqual(NeedIcon.symbol(for: "warm the milk bottle"), "waterbottle")
        XCTAssertEqual(NeedIcon.symbol(for: "burp cloth nearby"), "tshirt")
        XCTAssertEqual(NeedIcon.symbol(for: "eat with a plate"), "fork.knife")
        XCTAssertEqual(NeedIcon.symbol(for: "diaper change"), "arrow.triangle.2.circlepath")
        XCTAssertEqual(NeedIcon.symbol(for: "nap time in bed"), "moon")
    }

    func testCombinedPhrasingsPreferTheSpecificRow() {
        // "water bottle" names a bottle, not a glass of water.
        XCTAssertEqual(NeedIcon.symbol(for: "keep the water bottle full"), "waterbottle")
        // The baby row leads, even when food words follow.
        XCTAssertEqual(NeedIcon.symbol(for: "eating one-handed, take the baby"), "figure.and.child.holdinghands")
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(NeedIcon.symbol(for: "WATER"), "drop")
        XCTAssertEqual(NeedIcon.symbol(for: "Take The Baby"), "figure.and.child.holdinghands")
    }

    func testFallbackIsHeart() {
        XCTAssertEqual(NeedIcon.symbol(for: "something else entirely"), "heart")
        XCTAssertEqual(NeedIcon.symbol(for: ""), "heart")
    }

    func testNeedMatchesOnHerWords() {
        let need = Need(id: "take-baby", authorText: "eating one-handed, take the baby", cueWording: "", priority: 0)
        XCTAssertEqual(NeedIcon.symbol(for: need), "figure.and.child.holdinghands")
    }

    func testNeedWithBlankWordsMatchesOnID() {
        let need = Need(id: "refill-water", authorText: "", cueWording: "", priority: 1)
        XCTAssertEqual(NeedIcon.symbol(for: need), "drop")
    }
}
