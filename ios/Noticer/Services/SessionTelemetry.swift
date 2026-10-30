import Foundation
import NoticerCore

/// Pure telemetry helpers for the dev panel. Display only; the engine never
/// reads these.
enum SessionTelemetry {
    /// Ids the engine dropped as unknown, oldest first, capped. The model
    /// sometimes invents `need_id` strings (e.g. "no_need") or paraphrases a
    /// listed id instead of copying it exactly; those turns surface here so a
    /// live run shows what the model actually sent.
    static func droppedNeedIDs(from events: [EngineEvent], cap: Int = 8) -> [String] {
        var ids: [String] = []
        for event in events {
            guard event.kind == .assessmentDropped,
                  event.detail == "unknown-need",
                  let needID = event.needID,
                  !needID.isEmpty,
                  ids.last != needID
            else {
                continue
            }
            ids.append(needID)
        }
        return Array(ids.suffix(cap))
    }

    static func droppedLine(_ ids: [String]) -> String {
        ids.isEmpty ? "dropped: —" : "dropped: \(ids.joined(separator: ", "))"
    }
}
