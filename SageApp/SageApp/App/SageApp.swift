import SwiftUI

@main
@MainActor
struct SageApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootSceneView()
                .environment(environment)
                .environment(environment.settings)
                .task {
                    await environment.authStore.restoreSession()
                    await environment.authStore.bootstrapApp()
                }
        }
    }
}

private enum RootTab: String, Hashable {
    case inbox
    case tasks
    case timeline
    case notes
    case ai
}

private enum GlobalSheet: Identifiable {
    case search
    case tags
    case settings

    var id: Int { hashValue }
}

@MainActor
struct RootSceneView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings

    var body: some View {
        Group {
            switch environment.authStore.phase {
            case .launching:
                ZStack {
                    LinearGradient(colors: [.orange.opacity(0.18), .clear, .yellow.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .ignoresSafeArea()
                    LoadingStateView()
                }
            case .signedOut:
                AuthSceneView()
            case .signedIn:
                MainShellView()
            }
        }
        .environment(\.locale, settings.locale)
        .preferredColorScheme(settings.colorSchemeOverride)
        .animation(.spring(response: 0.32, dampingFraction: 0.84), value: environment.authStore.phase)
    }
}

@MainActor
private struct MainShellView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @SceneStorage("mainShellSelection") private var selectionRawValue = RootTab.inbox.rawValue
    @State private var activeSheet: GlobalSheet?

    private var sheetColorSchemeID: String {
        switch settings.sheetPreferredColorScheme {
        case .dark:
            return "dark"
        case .light:
            return "light"
        @unknown default:
            return "system"
        }
    }

    var body: some View {
        TabView(selection: selectionBinding) {
            NavigationStack {
                InboxView()
                    .toolbar { toolbar }
            }
            .tag(RootTab.inbox)
            .tabItem { Label(localizedAppText(for: settings.language, chinese: "收件箱", english: "Inbox"), systemImage: "tray.full") }

            NavigationStack {
                TasksView()
                    .toolbar { toolbar }
            }
            .tag(RootTab.tasks)
            .tabItem { Label(localizedAppText(for: settings.language, chinese: "任务", english: "Tasks"), systemImage: "checklist") }

            NavigationStack {
                TimelineScreen()
                    .toolbar { toolbar }
            }
            .tag(RootTab.timeline)
            .tabItem { Label(localizedAppText(for: settings.language, chinese: "日程", english: "Timeline"), systemImage: "calendar") }

            NavigationStack {
                NotesView()
                    .toolbar { toolbar }
            }
            .tag(RootTab.notes)
            .tabItem { Label(localizedAppText(for: settings.language, chinese: "笔记", english: "Notes"), systemImage: "note.text") }

            NavigationStack {
                AIAssistantView()
                    .toolbar { toolbar }
            }
            .tag(RootTab.ai)
            .tabItem { Label(localizedAppText(for: settings.language, chinese: "AI", english: "AI"), systemImage: "sparkles") }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .search:
                NavigationStack { SearchView() }
                    .environment(\.locale, settings.locale)
                    .preferredColorScheme(settings.sheetPreferredColorScheme)
                    .id("\(settings.language.rawValue)-\(settings.theme.rawValue)-\(sheetColorSchemeID)-search")
            case .tags:
                NavigationStack { TagsView() }
                    .environment(\.locale, settings.locale)
                    .preferredColorScheme(settings.sheetPreferredColorScheme)
                    .id("\(settings.language.rawValue)-\(settings.theme.rawValue)-\(sheetColorSchemeID)-tags")
            case .settings:
                NavigationStack { SettingsView() }
                    .environment(\.locale, settings.locale)
                    .preferredColorScheme(settings.sheetPreferredColorScheme)
                    .id("\(settings.language.rawValue)-\(settings.theme.rawValue)-\(sheetColorSchemeID)-settings")
            }
        }
        .background(
            LinearGradient(
                colors: [.orange.opacity(0.10), .clear, .yellow.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
    }

    private var selectionBinding: Binding<RootTab> {
        Binding(
            get: { RootTab(rawValue: selectionRawValue) ?? .inbox },
            set: { selectionRawValue = $0.rawValue }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                activeSheet = .search
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            Menu {
                Button {
                    activeSheet = .tags
                } label: {
                    Label("menu.tags", systemImage: "tag")
                }

                Button {
                    activeSheet = .settings
                } label: {
                    Label("menu.settings", systemImage: "gearshape")
                }

                Divider()

                Button(role: .destructive) {
                    Task { @MainActor in
                        await environment.authStore.logout()
                    }
                } label: {
                    Label("settings.logout", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
            }
        }
    }
}
