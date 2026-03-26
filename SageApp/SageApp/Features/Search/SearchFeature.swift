import SwiftUI
import Observation

@MainActor
@Observable
final class SearchViewModel {
    var query = ""
    var results = SearchResultsDTO(tasks: [], notes: [], tags: [])
    var isLoading = false
    var errorMessage: String?

    func search(using api: APIClient) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            results = SearchResultsDTO(tasks: [], notes: [], tags: [])
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await api.send(
                path: makeAPIPath(
                    "/api/mobile/v1/search",
                    queryItems: [URLQueryItem(name: "q", value: query)]
                )
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct SearchView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = SearchViewModel()
    @State private var selectedTask: TaskSearchDTO?
    @State private var selectedNoteID: String?
    @State private var selectedTag: TagSearchDTO?
    @State private var loadedTask: TaskDTO?
    @State private var loadedNote: NoteDTO?
    @State private var loadedTagDetail: TagDetailDTO?

    var body: some View {
        List {
            if viewModel.query.isEmpty {
                EmptyStateView(systemName: "magnifyingglass", title: "search.empty.title", message: "search.empty.message")
                    .listRowBackground(Color.clear)
            } else if viewModel.isLoading {
                LoadingStateView()
                    .listRowBackground(Color.clear)
            } else if viewModel.results.tasks.isEmpty && viewModel.results.notes.isEmpty && viewModel.results.tags.isEmpty {
                EmptyStateView(systemName: "sparkle.magnifyingglass", title: "search.noResults.title", message: "search.noResults.message")
                    .listRowBackground(Color.clear)
            } else {
                if !viewModel.results.tasks.isEmpty {
                    Section("tasks.title") {
                        ForEach(viewModel.results.tasks) { task in
                            Button {
                                Task { @MainActor in
                                    await openTask(task.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(task.title)
                                    Text(LocalizedStringKey(task.status.localizationKey))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .sageListRowChrome()
                        }
                    }
                }

                if !viewModel.results.notes.isEmpty {
                    Section("notes.title") {
                        ForEach(viewModel.results.notes) { note in
                            Button {
                                Task { @MainActor in
                                    await openNote(note.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(note.title)
                                    Text(note.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .sageListRowChrome()
                        }
                    }
                }

                if !viewModel.results.tags.isEmpty {
                    Section("tags.title") {
                        ForEach(viewModel.results.tags) { tag in
                            Button {
                                Task { @MainActor in
                                    await openTag(tag.id)
                                }
                            } label: {
                                TagChipView(tag: TagDTO(id: tag.id, name: tag.name, slug: tag.slug, color: tag.color, icon: nil, description: nil, sortOrder: 0, taskCount: nil, noteCount: nil, createdAt: "", updatedAt: ""))
                            }
                            .sageListRowChrome()
                        }
                    }
                }
            }
        }
        .sageListChrome()
        .searchable(text: $viewModel.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("search.placeholder"))
        .navigationTitle(localizedAppText(for: settings.language, chinese: "搜索", english: "Search"))
        .onSubmit(of: .search) {
            Task { @MainActor in
                await viewModel.search(using: environment.apiClient)
            }
        }
        .sheet(item: $loadedTask) { task in
            TaskEditorSheet(task: task, tags: task.tags) { _ in }
        }
        .sheet(item: $loadedNote) { note in
            NoteEditorSheet(note: note, tags: note.tags) { _ in }
        }
        .sheet(item: $loadedTagDetail) { detail in
            NavigationStack {
                List {
                    Section {
                        TagChipView(tag: detail.tag)
                            .sageListRowChrome()
                    }
                }
                .sageListChrome()
                .navigationTitle(detail.tag.name)
            }
        }
    }

    private func openTask(_ id: String) async {
        loadedTask = try? await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(id)")
    }

    private func openNote(_ id: String) async {
        loadedNote = try? await environment.apiClient.send(path: "/api/mobile/v1/notes/\(id)")
    }

    private func openTag(_ id: String) async {
        loadedTagDetail = try? await environment.apiClient.send(path: "/api/mobile/v1/tags/\(id)/detail")
    }
}
