import Foundation

/// Offline migration that backfills `handledCondition` and `selfNoticeSignal`
/// on saved needs that predate polarity fields, without calling the model.
public enum NeedPolarityMigration {
    public struct Result: Equatable, Sendable {
        public var needs: [Need]
        /// Need ids whose text did not match the small keyword map and stayed `nil`.
        public var needsPolarityReviewIDs: [String]
        /// Need ids whose visualCondition was rewritten to invert polarity.
        public var polarityRewrittenIDs: [String]

        public init(needs: [Need], needsPolarityReviewIDs: [String], polarityRewrittenIDs: [String] = []) {
            self.needs = needs
            self.needsPolarityReviewIDs = needsPolarityReviewIDs
            self.polarityRewrittenIDs = polarityRewrittenIDs
        }
    }

    public static func migrate(_ input: [Need]) -> Result {
        var output: [Need] = []
        output.reserveCapacity(input.count)
        var reviewIDs: [String] = []
        var rewrittenIDs: [String] = []

        for var need in input {
            let trimmedHandled = need.handledCondition?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedHandled.isEmpty {
                output.append(need)
                continue
            }

            let haystack = [need.id, need.authorText, need.visualCondition ?? ""]
                .joined(separator: " ")
                .lowercased()

            if haystack.contains("burp cloth") {
                need.handledCondition = "burp cloth within partner's reach"
                if (need.selfNoticeSignal ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    need.selfNoticeSignal = "wearer_bringing_burp_cloth"
                }
            } else if haystack.contains("water") {
                if haystack.contains("table") {
                    need.handledCondition = "water bottle on the dining table"
                    if (need.selfNoticeSignal ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        need.selfNoticeSignal = "wearer_placing_water_bottle_on_table"
                    }
                    if let visual = need.visualCondition?.lowercased(),
                       !visual.contains("no "),
                       !visual.contains("without"),
                       !visual.contains("empty"),
                       !visual.contains("missing") {
                        need.visualCondition = "dining table visible with no water bottle"
                        rewrittenIDs.append(need.id)
                    }
                } else {
                    need.handledCondition = "glass or bottle of water within reach"
                    if (need.selfNoticeSignal ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        need.selfNoticeSignal = ActionCodeExamples.wearerCarryingWaterTowardPartner
                    }
                }
            } else if haystack.contains("baby") {
                need.handledCondition = "partner eating with both hands free"
                if (need.selfNoticeSignal ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    need.selfNoticeSignal = ActionCodeExamples.wearerHandsReceivingBaby
                }
            } else {
                reviewIDs.append(need.id)
            }

            output.append(need)
        }

        return Result(needs: output, needsPolarityReviewIDs: reviewIDs, polarityRewrittenIDs: rewrittenIDs)
    }
}
