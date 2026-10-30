import Foundation

/// Mom's list while she is editing it. The engine keeps using `Need.id`.
/// `Need.uiID` is only so a row can be renamed and removed without the list
/// losing track of which card that was.
public enum NeedListEditing {
    /// A short id for the model, taken from her words. Empty text stays unnamed.
    public static func readableID(from text: String, avoiding taken: Set<String>) -> String? {
        var slug = ""
        var pendingHyphen = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingHyphen, !slug.isEmpty {
                    slug.append("-")
                }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty {
                pendingHyphen = true
            }
            if slug.count >= 48 {
                break
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        guard !slug.isEmpty else {
            return nil
        }
        if !taken.contains(slug) {
            return slug
        }
        var suffix = 2
        while taken.contains("\(slug)-\(suffix)") {
            suffix += 1
        }
        return "\(slug)-\(suffix)"
    }

    /// Turns a freshly added UUID into a slug from her words. An id that is
    /// already a slug stays put. Missing rows are left alone.
    @discardableResult
    public static func nameNeed(_ needs: inout [Need], uiID: UUID) -> Bool {
        guard let index = needs.firstIndex(where: { $0.uiID == uiID }),
              UUID(uuidString: needs[index].id) != nil
        else {
            return false
        }
        let taken = Set(needs.enumerated().compactMap { offset, need in
            offset == index ? nil : need.id
        })
        guard let slug = readableID(from: needs[index].authorText, avoiding: taken) else {
            return false
        }
        needs[index].id = slug
        return true
    }

    /// Removes one card by its editor identity. A second call for the same
    /// identity does nothing.
    @discardableResult
    public static func delete(_ needs: inout [Need], uiID: UUID) -> Bool {
        guard let index = needs.firstIndex(where: { $0.uiID == uiID }) else {
            return false
        }
        needs.remove(at: index)
        return true
    }
}
