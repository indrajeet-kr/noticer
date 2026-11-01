import SwiftUI

/// App root: onboarding until it's done, then three tabs — Tonight, Her
/// list, Learning. Streaming pauses if the app leaves the foreground. The
/// model is the only owner of the idle timer: the screen stays awake while a
/// session or Demo mode wants it, and sleeps when the view leaves. Night
/// look is a persisted in-app toggle, applied at the root.
struct RootView: View {
    @Bindable var model: PhoneSessionModel
    @AppStorage("noticer.onboarding.done") private var onboardingDone = false
    @AppStorage("noticer.appearance.night") private var night = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showingWins = false
    @State private var wasRunning = false

    var body: some View {
        Group {
            if onboardingDone {
                TabView(selection: $tab) {
                    LiveSessionView(model: model, onWins: { showingWins = true })
                        .tabItem { Label("Tonight", systemImage: "circle.circle") }
                        .tag(0)
                    MomsListView(model: model, onWins: { showingWins = true })
                        .tabItem { Label("Her list", systemImage: "list.bullet") }
                        .tag(1)
                    LearningView(model: model, onWins: { showingWins = true })
                        .tabItem { Label("Learning", systemImage: "leaf") }
                        .tag(2)
                }
                .tint(Theme.sage)
            } else {
                OnboardingView(model: model, done: $onboardingDone)
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(night ? .dark : .light)
        .animation(Theme.gentle, value: onboardingDone)
        .sheet(isPresented: $showingWins) {
            TeamWinsView(model: model)
        }
        .onAppear {
            model.reloadLibrary()
            model.refreshKeyStatus()
            wasRunning = model.isRunning
            model.refreshIdleTimer()
        }
        .onDisappear {
            model.releaseIdleTimer()
        }
        .onChange(of: scenePhase) { _, phase in
            let ticket = model.setSceneActive(phase == .active)
            Task {
                await model.propagateForeground(ticket)
            }
        }
        .onChange(of: model.isRunning) { _, running in
            defer { wasRunning = running }
            guard wasRunning, !running, !model.tonightMoments.isEmpty else {
                return
            }
            showingWins = true
        }
    }
}

#Preview("Root") {
    RootView(model: PhoneSessionModel())
}
