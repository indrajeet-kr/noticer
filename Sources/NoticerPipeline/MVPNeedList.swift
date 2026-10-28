import Foundation
import NoticerCore

/// The two MVP needs. Ids match the need engine's tests and the PRD's pair:
/// one-handed eating, and nursing without water.
public enum MVPNeedList {
    public static let takeBabyID = "take-baby"
    public static let refillWaterID = "refill-water"

    public static let takeBaby = Need(
        id: takeBabyID,
        authorText: "eating one-handed, take the baby",
        cueWording: "Her plate's getting cold, maybe take the baby?",
        visualCondition: "partner eating with one hand and holding the baby",
        selfNoticeSignal: ActionCodeExamples.wearerHandsReceivingBaby,
        priority: 0
    )

    public static let refillWater = Need(
        id: refillWaterID,
        authorText: "nursing, no water",
        cueWording: "Her water's empty.",
        visualCondition: "partner nursing without water in reach",
        selfNoticeSignal: ActionCodeExamples.wearerCarryingWaterTowardPartner,
        priority: 1
    )

    public static let all = [takeBaby, refillWater]
}
