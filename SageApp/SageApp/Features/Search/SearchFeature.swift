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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = SearchResultsDTO(tasks: [], notes: [], tags: [])
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            results = try await api.send(
                path: makeAPIPath(
                    "/api/mobile/v1/search",
                    queryItems: [URLQueryItem(name: "q", value: trimmed)]
                )
            )
            errorMessage = nil
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
    @FocusState private var searchFocused: Bool
    @State private var recentQueries = UserDefaults.standard.stringArray(forKey: "sage.search.recents") ?? []
    @State private var destination: SearchNavigationDestination?

    let shouldAutoFocus: Bool

    init(shouldAutoFocus: Bool = false) {
        self.shouldAutoFocus = shouldAutoFocus
    }

    var body: some View {
        List {
            searchFieldSection

            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage, retry: {
                    Task { @MainActor in
                        await viewModel.search(using: environment.apiClient)
                    }
                })
                .listRowBackground(Color.clear)
            } else if viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recentSearchesSection
            } else if viewModel.isLoading {
                LoadingStateView()
                    .listRowBackground(Color.clear)
            } else if viewModel.results.tasks.isEmpty && viewModel.results.notes.isEmpty && viewModel.results.tags.isEmpty {
                EmptyStateView(systemName: "magnifyingglass", title: "search.noResults.title", message: "search.noResults.message")
                    .listRowBackground(Color.clear)
            } else {
                topResultsSection

                if !viewModel.results.tasks.isEmpty {
                    Section(localizedAppText(for: settings.language, chinese: "任务", english: "Tasks")) {
                        ForEach(viewModel.results.tasks) { task in
                            Button {
                                Task { @MainActor in
                                    await openTask(task.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(task.title)
                                        .font(.body.weight(.semibold))
                                    Text(LocalizedStringKey(task.status.localizationKey))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .sageListRowChrome()
                        }
                    }
                }

                if !viewModel.results.notes.isEmpty {
                    Section(localizedAppText(for: settings.language, chinese: "笔记", english: "Notes")) {
                        ForEach(viewModel.results.notes) { note in
                            Button {
                                Task { @MainActor in
                                    await openNote(note.id)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(note.title)
                                        .font(.body.weight(.semibold))
                                    Text(note.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .sageListRowChrome()
                        }
                    }
                }

                if !viewModel.results.tags.isEmpty {
                    Section(localizedAppText(for: settings.language, chinese: "标签", english: "Tags")) {
                        ForEach(viewModel.results.tags) { tag in
                            Button {
                                Task { @MainActor in
                                    await openTag(tag.id)
                                }
                            } label: {
                                HStack {
                                    TagChipView(tag: TagDTO(id: tag.id, name: tag.name, slug: tag.slug, color: tag.color, icon: nil, description: nil, sortOrder: 0, taskCount: nil, noteCount: nil, createdAt: "", updatedAt: ""))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .sageListRowChrome()
                        }
                    }
                }
            }
        }
        .sageListChrome()
        .navigationTitle(localizedAppText(for: settings.language, chinese: "搜索", english: "Search"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if shouldAutoFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    searchFocused = true
                }
            }
        }
        .navigationDestination(item: $destination) { destination in
            switch destination {
            case let .task(task, tags):
                TaskDetailView(task: task, availableTags: tags) { _ in } onDelete: { _ in }
            case let .note(note, tags):
                NoteDetailView(note: note, availableTags: tags) { _ in } onDelete: {}
            case let .tag(tag, tags):
                TagDetailView(tag: tag, availableTags: tags)
            }
        }
    }

    @ViewBuilder
    private var searchFieldSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(localizedAppText(for: settings.language, chinese: "搜索任务、笔记、标签", english: "Search tasks, notes, tags"), text: $viewModel.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        persistRecentQuery()
                        Task { @MainActor in
                            await viewModel.search(using: environment.apiClient)
                        }
                    }
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                        viewModel.results = SearchResultsDTO(tasks: [], notes: [], tags: [])
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous)
                    .strokeBorder(SagePalette.separator)
            )
        }
        .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var recentSearchesSection: some View {
        if recentQueries.isEmpty {
            EmptyStateView(systemName: "magnifyingglass", title: "search.empty.title", message: "search.empty.message")
                .listRowBackground(Color.clear)
        } else {
            Section(localizedAppText(for: settings.language, chinese: "最近搜索", english: "Recent searches")) {
                ForEach(recentQueries, id: \.self) { recent in
                    Button {
                        viewModel.query = recent
                        Task { @MainActor in
                            await viewModel.search(using: environment.apiClient)
                        }
                    } label: {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(recent)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .sageListRowChrome()
                }
            }
        }
    }

    @ViewBuilder
    private var topResultsSection: some View {
        let top = Array((viewModel.results.tasks.map { SearchTopResult.task($0.id, $0.title) }
            + viewModel.results.notes.map { SearchTopResult.note($0.id, $0.title) }
            + viewModel.results.tags.map { SearchTopResult.tag($0.id, $0.name) }).prefix(3))

        if !top.isEmpty {
            Section(localizedAppText(for: settings.language, chinese: "最佳匹配", english: "Top results")) {
                ForEach(top, id: \.id) { result in
                    Button {
                        Task { @MainActor in
                            switch result {
                            case let .task(id, _):
                                await openTask(id)
                            case let .note(id, _):
                                await openNote(id)
                            case let .tag(id, _):
                                await openTag(id)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: result.symbolName)
                                .foregroundStyle(SagePalette.brand)
                            Text(result.title)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .sageListRowChrome()
                }
            }
        }
    }

    private func persistRecentQuery() {
        let trimmed = viewModel.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentQueries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentQueries.insert(trimmed, at: 0)
        recentQueries = Array(recentQueries.prefix(8))
        UserDefaults.standard.set(recentQueries, forKey: "sage.search.recents")
    }

    private func openTask(_ id: String) async {
        do {
            async let taskRequest: TaskDTO = environment.apiClient.send(path: "/api/mobile/v1/tasks/\(id)")
            async let tagsRequest: [TagDTO] = environment.apiClient.send(path: "/api/mobile/v1/tags")
            destination = try await .task(taskRequest, tagsRequest)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func openNote(_ id: String) async {
        do {
            async let noteRequest: NoteDTO = environment.apiClient.send(path: "/api/mobile/v1/notes/\(id)")
            async let tagsRequest: [TagDTO] = environment.apiClient.send(path: "/api/mobile/v1/tags")
            destination = try await .note(noteRequest, tagsRequest)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private func openTag(_ id: String) async {
        do {
            async let detailRequest: TagDetailDTO = environment.apiClient.send(path: "/api/mobile/v1/tags/\(id)/detail")
            async let tagsRequest: [TagDTO] = environment.apiClient.send(path: "/api/mobile/v1/tags")
            let detail = try await detailRequest
            destination = try await .tag(detail.tag, tagsRequest)
        } catch {
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

private enum SearchNavigationDestination: Hashable, Identifiable {
    case task(TaskDTO, [TagDTO])
    case note(NoteDTO, [TagDTO])
    case tag(TagDTO, [TagDTO])

    var id: String {
        switch self {
        case let .task(task, _):
            return "task-\(task.id)"
        case let .note(note, _):
            return "note-\(note.id)"
        case let .tag(tag, _):
            return "tag-\(tag.id)"
        }
    }
}

private enum SearchTopResult {
    case task(String, String)
    case note(String, String)
    case tag(String, String)

    var id: String {
        switch self {
        case let .task(id, _):
            return "task-\(id)"
        case let .note(id, _):
            return "note-\(id)"
        case let .tag(id, _):
            return "tag-\(id)"
        }
    }

    var title: String {
        switch self {
        case let .task(_, title), let .note(_, title), let .tag(_, title):
            return title
        }
    }

    var symbolName: String {
        switch self {
        case .task:
            return "checklist"
        case .note:
            return "note.text"
        case .tag:
            return "tag"
        }
    }
}
