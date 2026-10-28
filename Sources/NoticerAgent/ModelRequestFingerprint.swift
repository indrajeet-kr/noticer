import Foundation
import NoticerCore

/// Stable identity of a model request. JPEG bytes are hashed, not stored.
public enum ModelRequestFingerprint {
    public static func make(_ request: ModelRequest) -> String {
        var lines = ["v1"]
        for (index, frame) in request.keyframes.enumerated() {
            let age = Int((frame.ageSeconds * 1000).rounded())
            lines.append(
                "k\(index)|\(frame.id)|\(age)|\(frame.episodeID)|\(frame.jpegData.count)|\(fnv64(frame.jpegData))"
            )
        }
        for (index, need) in request.needs.enumerated() {
            lines.append("n\(index)|\(need.id)")
        }
        return lines.joined(separator: "\n")
    }

    public static func fileID(for request: ModelRequest) -> String {
        "fp-" + fnv64(Data(make(request).utf8))
    }

    static func fnv64(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
