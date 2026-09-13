import SwiftUI

@main
struct SheetXApp: App {
    @StateObject private var settings = AppSettings.shared
    @StateObject private var library = Library.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(library)
                .environment(\.layoutDirection, settings.language.layoutDirection)
                .preferredColorScheme(settings.colorScheme)
                .tint(.accentColor)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var library: Library
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            FilesView()
                .tabItem { Label("tab.files".loc, systemImage: "tablecells") }
                .tag(0)
            ReportsView()
                .tabItem { Label("tab.reports".loc, systemImage: "doc.text.magnifyingglass") }
                .tag(1)
            SettingsView()
                .tabItem { Label("tab.settings".loc, systemImage: "gearshape") }
                .tag(2)
        }
        .alert("common.error".loc, isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } })) {
            Button("common.ok".loc, role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .task { try? await settings.loadAPIKeys() }
        .onOpenURL { url in
            // Files opened via "Open in SheetX" / the Files app land here.
            guard url.isFileURL else { return }
            tab = 0
            library.importFiles([url], headerMode: settings.headerMode)
        }
    }
}
