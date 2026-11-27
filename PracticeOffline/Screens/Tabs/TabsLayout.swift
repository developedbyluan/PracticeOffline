import SwiftUI

/// Port of src/app/(tabs)/_layout.tsx: the four bottom tabs.
struct TabsLayout: View {
    var body: some View {
        TabView {
            HomeScreen()
                .tabItem { Label("Home", systemImage: "house") }
            SessionsScreen()
                .tabItem { Label("Sessions", systemImage: "clock") }
            PinnedScreen()
                .tabItem { Label("Pinned", systemImage: "pin") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        // In-app messages, usable from any tab: Toast.show(...)
        .toastHost()
    }
}

/// src/app/(tabs)/sessions.tsx (placeholder)
struct SessionsScreen: View {
    var body: some View { PlaceholderScreen(title: "Sessions") }
}

/// src/app/(tabs)/pinned.tsx (placeholder)
struct PinnedScreen: View {
    var body: some View { PlaceholderScreen(title: "Pinned") }
}

/// src/app/(tabs)/settings.tsx (placeholder)
struct SettingsScreen: View {
    var body: some View { PlaceholderScreen(title: "Settings") }
}

/// Empty screen showing just its name, until the real screen is ported.
private struct PlaceholderScreen: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    TabsLayout()
}
