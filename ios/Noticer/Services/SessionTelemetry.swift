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

    /// " · 8:12 PM" for dev lines, or "" when there is no time yet.
    static func timeSuffix(_ date: Date?) -> String {
        guard let date else {
            return ""
        }
        return " · \(timeFormatter.string(from: date))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    /// Engine event timeline, oldest first, capped: "09:37:12 needLatched
    /// water". Snapshots can miss a whole open→close cycle when it completes
    /// inside one awaited model call; the event log never does.
    static func eventTimeline(from events: [EngineEvent], cap: Int = 8) -> [String] {
        events.suffix(cap).map { event in
            var parts = [clockTime(event.at), event.kind.rawValue]
            if let needID = event.needID {
                parts.append(needID)
            }
            if let detail = event.detail {
                parts.append(detail)
            }
            return parts.joined(separator: " ")
        }
    }

    static func clockTime(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
