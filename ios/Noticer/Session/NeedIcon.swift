import Foundation
import NoticerCore

/// Line SF Symbol for a need card tile, picked by keyword from her words.
/// Matching is case-insensitive substring on the lowercased text. Order
/// matters for combined phrasings: the bottle row sits above the water row
/// so "water bottle" reads as a bottle, and the baby row sits above food so
/// "take the baby so I can eat" reads as the baby.
enum NeedIcon {
    static func symbol(for text: String) -> String {
        let words = text.lowercased()
        if words.contains("baby") || words.contains("hold") || words.contains("take") {
            return "figure.and.child.holdinghands"
        }
        if words.contains("bottle") || words.contains("feed") || words.contains("milk") {
            return "waterbottle"
        }
        if words.contains("water") || words.contains("drink") || words.contains("refill") {
            return "drop"
        }
        if words.contains("burp") || words.contains("cloth") || words.contains("towel") {
            return "tshirt"
        }
        if words.contains("food") || words.contains("eat") || words.contains("plate") {
            return "fork.knife"
        }
        if words.contains("diaper") || words.contains("change") {
            return "arrow.triangle.2.circlepath"
        }
        if words.contains("sleep") || words.contains("nap") || words.contains("bed") {
            return "moon"
        }
        return "heart"
    }

    /// Matches on her words; falls back to the need id when the words are blank.
    static func symbol(for need: Need) -> String {
        let text = need.authorText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return symbol(for: text)
        }
        return symbol(for: need.id)
    }
}
