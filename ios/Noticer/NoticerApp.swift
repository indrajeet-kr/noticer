import SwiftUI

@main
struct NoticerApp: App {
    @State private var model = PhoneSessionModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.sessionLog.loadActivity()
                    model.sessionLog.logLaunch()
                    model.resetTonightIfNeeded()
                    model.watchAudioRoutes()
                    model.configureWearables()
                }
                .onOpenURL { url in
                    model.handle(url: url)
                }
        }
    }
}
