import SwiftUI

@main
struct NoticerApp: App {
    @State private var model = PhoneSessionModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    model.configureWearables()
                }
                .onOpenURL { url in
                    model.handle(url: url)
                }
        }
    }
}
