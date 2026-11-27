import SwiftUI

/// Port of src/app/(tabs)/_layout.tsx: the four bottom tabs.
struct TabsLayout: View {
    /// Shared, so tapping an event reminder can switch to the Pinned tab.
    @State private var navigation = AppNavigation.shared

    var body: some View {
        TabView(selection: $navigation.tab) {
            HomeScreen()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppNavigation.Tab.home)
            SessionsScreen()
                .tabItem { Label("Sessions", systemImage: "clock") }
                .tag(AppNavigation.Tab.sessions)
            PinnedScreen()
                .tabItem { Label("Pinned", systemImage: "pin") }
                .tag(AppNavigation.Tab.pinned)
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppNavigation.Tab.settings)
        }
        // In-app messages, usable from any tab: Toast.show(...)
        .toastHost()
    }
}

#Preview {
    TabsLayout()
}
