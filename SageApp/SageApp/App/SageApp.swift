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
    case plan
    case notes
    case ai
}

private enum AppDestination: Hashable {
    case search
    case tags
    case settings
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
                    SagePalette.groupedBackground
                        .ignoresSafeArea()

                    VStack(spacing: 18) {
                        Image("BrandMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        LoadingStateView()
                    }
                    .padding(.horizontal, 24)
                }
            case .signedOut:
                AuthSceneView()
            case .signedIn:
                MainShellView()
            }
        }
        .environment(\.locale, settings.locale)
        .preferredColorScheme(settings.colorSchemeOverride)
        .animation(.spring(response: 0.3, dampingFraction: 0.88), value: environment.authStore.phase)
    }
}

@MainActor
private struct MainShellView: View {
    @Environment(AppSettingsStore.self) private var settings
    @SceneStorage("mainShellSelection") private var selectionRawValue = RootTab.inbox.rawValue

    var body: some View {
        TabView(selection: selectionBinding) {
            InboxTabScene()
                .tag(RootTab.inbox)
                .tabItem {
                    Label(localizedAppText(for: settings.language, chinese: "收件箱", english: "Inbox"), systemImage: "tray.full")
                }

            TasksTabScene()
                .tag(RootTab.tasks)
                .tabItem {
                    Label(localizedAppText(for: settings.language, chinese: "任务", english: "Tasks"), systemImage: "checklist")
                }

            PlanTabScene()
                .tag(RootTab.plan)
                .tabItem {
                    Label(localizedAppText(for: settings.language, chinese: "规划", english: "Plan"), systemImage: "calendar")
                }

            NotesTabScene()
                .tag(RootTab.notes)
                .tabItem {
                    Label(localizedAppText(for: settings.language, chinese: "笔记", english: "Notes"), systemImage: "note.text")
                }

            AITabScene()
                .tag(RootTab.ai)
                .tabItem {
                    Label("AI", systemImage: "sparkles")
                }
        }
        .tint(SagePalette.brand)
    }

    private var selectionBinding: Binding<RootTab> {
        Binding(
            get: { RootTab(rawValue: selectionRawValue) ?? .inbox },
            set: { selectionRawValue = $0.rawValue }
        )
    }
}

@MainActor
private struct InboxTabScene: View {
    var body: some View {
        AppTabContainer {
            InboxView()
        }
    }
}

@MainActor
private struct TasksTabScene: View {
    var body: some View {
        AppTabContainer {
            TasksView()
        }
    }
}

@MainActor
private struct PlanTabScene: View {
    var body: some View {
        AppTabContainer {
            TimelineScreen()
        }
    }
}

@MainActor
private struct NotesTabScene: View {
    var body: some View {
        AppTabContainer {
            NotesView()
        }
    }
}

@MainActor
private struct AITabScene: View {
    var body: some View {
        AppTabContainer {
            AIAssistantView()
        }
    }
}

@MainActor
private struct AppTabContainer<Content: View>: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings

    @State private var path = NavigationPath()
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: AppDestination.self) { destination in
                    switch destination {
                    case .search:
                        SearchView(shouldAutoFocus: true)
                    case .tags:
                        TagsView()
                    case .settings:
                        SettingsView()
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            path.append(AppDestination.search)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }

                        Menu {
                            Button {
                                path.append(AppDestination.tags)
                            } label: {
                                Label(localizedAppText(for: settings.language, chinese: "标签", english: "Tags"), systemImage: "tag")
                            }

                            Button {
                                path.append(AppDestination.settings)
                            } label: {
                                Label(localizedAppText(for: settings.language, chinese: "设置", english: "Settings"), systemImage: "gearshape")
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
                        }
                    }
                }
        }
    }
}
