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

#Preview {
    TabsLayout()
}
