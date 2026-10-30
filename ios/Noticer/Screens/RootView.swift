import SwiftUI
import UIKit

/// App root: onboarding until it's done, then the five tabs. Owns the
/// foreground/idle-timer contract the old ContentView held: streaming pauses
/// if the app leaves the foreground, and the screen stays on in a session.
struct RootView: View {
    @Bindable var model: PhoneSessionModel
    @AppStorage("noticer.onboarding.done") private var onboardingDone = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    var body: some View {
        Group {
            if onboardingDone {
                TabView(selection: $tab) {
                    MomsListView(model: model)
                        .tabItem { Label("Her list", systemImage: "list.bullet") }
                        .tag(0)
                    LiveSessionView(model: model)
                        .tabItem { Label("Live", systemImage: "circle") }
                        .tag(1)
                    ReplayView(model: model)
                        .tabItem { Label("Replay", systemImage: "arrow.counterclockwise") }
                        .tag(2)
                    LearningView(model: model)
                        .tabItem { Label("Learning", systemImage: "chart.line.uptrend.xyaxis") }
                        .tag(3)
                    TeamWinsView(model: model)
                        .tabItem { Label("Wins", systemImage: "heart") }
                        .tag(4)
                }
                .tint(Theme.accentWarm)
            } else {
                OnboardingView(model: model, done: $onboardingDone)
                    .transition(.opacity)
            }
        }
        .animation(Theme.gentle, value: onboardingDone)
        .onAppear {
            model.reloadLibrary()
            model.refreshKeyStatus()
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
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = model.keepsScreenOn && scenePhase == .active
    }
}

#Preview("Root") {
    RootView(model: PhoneSessionModel())
}
