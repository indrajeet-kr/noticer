import SwiftUI
import UIKit

/// App root: onboarding until it's done, then three tabs — Tonight, Her
/// list, Learning. Owns the foreground/idle-timer contract the old
/// ContentView held: streaming pauses if the app leaves the foreground, and
/// the screen stays on in a session. Night look is a persisted in-app toggle,
/// applied at the root.
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
            updateIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                await model.setForeground(phase == .active)
            }
            updateIdleTimer()
        }
        .onChange(of: model.keepsScreenOn) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: model.isRunning) { _, running in
            defer { wasRunning = running }
            guard wasRunning, !running, !model.moments.isEmpty else {
                return
            }
            showingWins = true
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = model.keepsScreenOn && scenePhase == .active
    }
}

#Preview("Root") {
    RootView(model: PhoneSessionModel())
}
