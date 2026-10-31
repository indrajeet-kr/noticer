import SwiftUI

/// Where the tab's top-right menu can go. Wins presents as a sheet; Replay
/// and Settings push in the tab's `NavigationStack`.
enum TabMenuDestination: Hashable {
    case replay
    case settings
    case help
}

/// The top-right `ellipsis.circle` menu on each tab: Tonight's wins, Replay,
/// Settings, Help.
struct TabTopMenu: View {
    var onWins: () -> Void
    var onSelect: (TabMenuDestination) -> Void

    var body: some View {
        Menu {
            Button("Tonight's wins", systemImage: "heart") {
                onWins()
            }
            Button("Replay", systemImage: "arrow.counterclockwise") {
                onSelect(.replay)
            }
            Button("Settings", systemImage: "gearshape") {
                onSelect(.settings)
            }
            Button("Help", systemImage: "questionmark.circle") {
                onSelect(.help)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title2)
                .fontWeight(.light)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("More actions")
    }
}

extension View {
    /// Pushes the menu destinations for a tab's `NavigationPath`.
    func tabMenuDestinations(model: PhoneSessionModel) -> some View {
        navigationDestination(for: TabMenuDestination.self) { destination in
            switch destination {
            case .replay:
                ReplayView(model: model)
            case .settings:
                AskSettingsView(model: model)
            case .help:
                HelpView()
            }
        }
    }
}
