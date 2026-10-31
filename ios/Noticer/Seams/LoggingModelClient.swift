import Foundation
import NoticerCore

/// Decorator around the live model client. Logs what each turn reads
/// (keyframes, needs) and what comes back (tool, assessment, latency).
/// Passes every call and error through untouched: zero behavior change.
/// Neither side ever carries the API key.
struct LoggingModelClient: ModelClient {
    var inner: any ModelClient
    var log: @Sendable (String, String) -> Void

    func complete(_ request: ModelRequest) async throws -> ModelVerdict {
        let start = Date()
        log("MODEL", Self.describeRequest(request))
        do {
            let verdict = try await inner.complete(request)
            log("MODEL", "\(Self.describeVerdict(verdict)) [\(Self.latency(start))s]")
            return verdict
        } catch is CancellationError {
            // A stop-time cancel is not a model failure; say so plainly.
            log("MODEL", "cancelled [\(Self.latency(start))s]")
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            log("MODEL", "cancelled [\(Self.latency(start))s]")
            throw error
        } catch {
            log("MODEL", "error: \(String(describing: error)) [\(Self.latency(start))s]")
            throw error
        }
    }

    static func describeRequest(_ request: ModelRequest) -> String {
        let purpose = request.purpose?.rawValue ?? "—"
        let ids = request.keyframes.map(\.id).joined(separator: ",")
        let ages = request.keyframes.map { String(Int($0.ageSeconds.rounded())) }.joined(separator: ",")
        let bytes = request.keyframes.reduce(0) { $0 + $1.jpegData.count }
        let needs = request.needs.map(\.id).joined(separator: ",")
        let open = request.openNeeds.map { "\($0.needID)\($0.cueSpoken ? ":spoken" : "")" }.joined(separator: ",")
        return "call purpose=\(purpose) keyframes=\(request.keyframes.count) ids=[\(ids)] ages=[\(ages)]s bytes=\(bytes) size=\(bytes / 1024)KB open=[\(open)] needs=[\(needs)]"
    }

    static func describeVerdict(_ verdict: ModelVerdict) -> String {
        let assessment = verdict.assessment
        // Omitted reads as —, never "null": the model also sends the literal
        // strings "none"/"null", and the log must tell them apart.
        return [
            verdict.tool.rawValue,
            "need=\(assessment.needID ?? "—")",
            "sustained=\(Self.flag(assessment.sustainedAcrossStrip))",
            "partner=\(Self.flag(assessment.partnerInView))",
            "hands=\(Self.flag(assessment.wearerHandsVisible))/occ=\(Self.flag(assessment.wearerHandsOccupied))",
            "res=\(assessment.resolution?.rawValue ?? "—")",
            "action=\(assessment.actionCode ?? "—")",
            "conf=\(assessment.confidence.map { String(format: "%.2f", $0) } ?? "—")",
            "finish=\(verdict.finishReason.rawValue)",
        ].joined(separator: " ")
    }

    private static func flag(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "null"
    }

    private static func latency(_ start: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(start))
    }
}
