import Foundation

enum SecretRedaction {
    static func redact(_ text: String, secrets: [String]) -> String {
        var redacted = text
        for secret in secrets where secret.count >= 4 {
            redacted = redacted.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return redacted
    }

    static func clip(_ text: String, limit: Int = 500) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit))
    }
}
