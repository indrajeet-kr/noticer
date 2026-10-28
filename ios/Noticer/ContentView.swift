import NoticerCore
import SwiftUI

/// Step 0 shell. It does not start a session, call a model, or play a cue.
struct ContentView: View {
    private let cueSpeaker: any CueSpeaker = GlassesCueSpeaker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Noticer")
                .font(.largeTitle)
            Text("Mom writes the list. Dad gets a head start, then a whisper only if he misses it.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("DAT SDK: \(DATCameraSeam.sdkLinked ? "linked" : "not linked")")
                Text("Live model: \(AgentSeam.liveModelID)")
                Text("API key: \(ModelKeyStore.environmentVariable), or the settings screen when it exists")
                Text(cueSpeaker is GlassesCueSpeaker ? "Cue path: glasses speaker stub" : "Cue path: custom")
            }
            .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    ContentView()
}
