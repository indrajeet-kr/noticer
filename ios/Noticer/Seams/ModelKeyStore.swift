import Foundation
import NoticerAgent

/// The Meta Model API key is never stored in the repo.
///
/// Live mode reads `META_API_KEY` from the environment. A settings screen may
/// later keep a key in the Keychain. This file does not persist one.
enum ModelKeyStore {
    static let environmentVariable = MuseSparkModelClient.apiKeyEnvironmentVariable

    static func environmentKey() -> String? {
        let value = ProcessInfo.processInfo.environment[environmentVariable]
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }
}
