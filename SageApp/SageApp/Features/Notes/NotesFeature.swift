import SwiftUI
import Observation

@MainActor
@Observable
final class NotesViewModel {
    var notes: [NoteDTO] = []
    var tags: [TagDTO] = []
    var query = ""
    var typeFilter: NoteType?
    var selectedTagID: String?
    var isLoading = false
    var errorMessage: String?

    func load(using api: APIClient) async {
        isLoading = true
        defer { isLoading = false }

        do {
            var components = URLComponents()
            components.queryItems = [
                URLQueryItem(name: "q", value: query.isEmpty ? nil : query),
                URLQueryItem(name: "type", value: typeFilter?.rawValue),
                URLQueryItem(name: "tag", value: selectedTagID)
            ].compactMap { item in
                item.value == nil ? nil : item
            }
            let notesPath = "/api/mobile/v1/notes" + (components.percentEncodedQuery.map { "?\($0)" } ?? "")
            async let notesRequest: [NoteDTO] = api.send(path: notesPath)
            async let tagsRequest: [TagDTO] = api.send(path: "/api/mobile/v1/tags")
            notes = try await notesRequest
            tags = try await tagsRequest
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String, using api: APIClient) async {
        do {
            let _: EmptySuccessDTO = try await api.send(path: "/api/mobile/v1/notes/\(id)", method: "DELETE", body: EmptyBody())
            notes.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct NotesView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = NotesViewModel()
    @State private var editingNote: NoteDTO?
    @State private var isCreatingNote = false

    var body: some View {
        List {
            Section {
                SurfaceCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField(
                                localizedAppText(for: settings.language, chinese: "搜索标题、摘要或内容", english: "Search title, summary or content"),
                                text: $viewModel.query
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit {
                                Task { @MainActor in
                                    await viewModel.load(using: environment.apiClient)
                                }
                            }

                            if !viewModel.query.isEmpty {
                                Button {
                                    viewModel.query = ""
                                    Task { @MainActor in
                                        await viewModel.load(using: environment.apiClient)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterChip(
                                    title: localizedAppText(for: settings.language, chinese: "全部类型", english: "All types"),
                                    isSelected: viewModel.typeFilter == nil
                                ) {
                                    viewModel.typeFilter = nil
                                }

                                ForEach(NoteType.allCases) { type in
                                    filterChip(
                                        title: localizedString(type.localizationKey),
                                        isSelected: viewModel.typeFilter == type
                                    ) {
                                        viewModel.typeFilter = viewModel.typeFilter == type ? nil : type
                                    }
                                }
                            }
                        }

                        if !viewModel.tags.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    filterChip(
                                        title: localizedAppText(for: settings.language, chinese: "全部标签", english: "All tags"),
                                        isSelected: viewModel.selectedTagID == nil
                                    ) {
                                        viewModel.selectedTagID = nil
                                    }

                                    ForEach(viewModel.tags) { tag in
                                        Button {
                                            viewModel.selectedTagID = viewModel.selectedTagID == tag.id ? nil : tag.id
                                        } label: {
                                            TagChipView(tag: tag)
                                                .opacity(viewModel.selectedTagID == nil || viewModel.selectedTagID == tag.id ? 1 : 0.42)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            notesContent
        }
        .sageListChrome()
        .navigationTitle(localizedAppText(for: settings.language, chinese: "笔记", english: "Notes"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    isCreatingNote = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .task {
            await viewModel.load(using: environment.apiClient)
        }
        .onChange(of: viewModel.typeFilter) { _, _ in
            Task { @MainActor in
                await viewModel.load(using: environment.apiClient)
            }
        }
        .onChange(of: viewModel.selectedTagID) { _, _ in
            Task { @MainActor in
                await viewModel.load(using: environment.apiClient)
            }
        }
        .sheet(item: $editingNote, content: noteEditor)
        .sheet(isPresented: $isCreatingNote) {
            NoteEditorSheet(note: nil, tags: viewModel.tags, onSave: handleNoteSaved)
        }
        .refreshable {
            await viewModel.load(using: environment.apiClient)
        }
    }

    @ViewBuilder
    private var notesContent: some View {
        if let errorMessage = viewModel.errorMessage {
            ErrorStateView(message: errorMessage, retry: {
                Task { @MainActor in
                    await viewModel.load(using: environment.apiClient)
                }
            })
            .listRowBackground(Color.clear)
        } else if viewModel.isLoading {
            LoadingStateView()
                .listRowBackground(Color.clear)
        } else if viewModel.notes.isEmpty {
            EmptyStateView(systemName: "note.text", title: "notes.empty.title", message: "notes.empty.message")
                .listRowBackground(Color.clear)
        } else {
            ForEach(viewModel.notes) { note in
                noteRow(note)
            }
        }
    }

    private func noteRow(_ note: NoteDTO) -> some View {
        NavigationLink {
            NoteDetailView(note: note, availableTags: viewModel.tags) { _ in
                handleNoteSaved(note)
            } onDelete: {
                reloadNotes()
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(note.title)
                    .font(.body.weight(.semibold))

                if !note.summary.isEmpty {
                    Text(note.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    MetadataBadge(systemName: "calendar", title: formattedDate(note.updatedAt), tint: .secondary)
                    MetadataBadge(systemName: "doc.text", title: localizedString(note.type.localizationKey), tint: .secondary)
                    MetadataBadge(systemName: "flag", title: localizedString(note.importance.localizationKey), tint: .secondary)
                }

                if !note.tags.isEmpty {
                    CompactTagStrip(tags: note.tags, limit: 2)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .sageListRowChrome()
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                editingNote = note
            } label: {
                Label("common.edit", systemImage: "square.and.pencil")
            }
            .tint(SagePalette.brand)

            Button(role: .destructive) {
                Task { @MainActor in
                    await viewModel.delete(id: note.id, using: environment.apiClient)
                }
            } label: {
                Label("common.delete", systemImage: "trash")
            }
        }
    }

    private func noteEditor(note: NoteDTO) -> some View {
        NoteEditorSheet(note: note, tags: viewModel.tags, onSave: handleNoteSaved, onDelete: reloadNotes)
    }

    private func handleNoteSaved(_: NoteDTO) {
        Task { @MainActor in
            await viewModel.load(using: environment.apiClient)
        }
    }

    private func reloadNotes() {
        Task { @MainActor in
            await viewModel.load(using: environment.apiClient)
        }
    }

    @ViewBuilder
    private func filterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? SagePalette.brand : Color(uiColor: .secondarySystemGroupedBackground))
                )
        }
        .buttonStyle(.plain)
    }

    private func localizedString(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), locale: settings.locale)
    }

    private func formattedDate(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .omitted) ?? string
    }
}

@MainActor
struct NoteDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let availableTags: [TagDTO]
    let onSave: (NoteDTO) -> Void
    let onDelete: () -> Void

    @State private var note: NoteDTO
    @State private var showingEditor = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    init(note: NoteDTO, availableTags: [TagDTO], onSave: @escaping (NoteDTO) -> Void, onDelete: @escaping () -> Void) {
        self.availableTags = availableTags
        self.onSave = onSave
        self.onDelete = onDelete
        _note = State(initialValue: note)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(note.title)
                        .font(.title2.weight(.semibold))

                    if !note.summary.isEmpty {
                        Text(note.summary)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        MetadataBadge(systemName: "doc.text", title: localizedString(note.type.localizationKey), tint: .secondary)
                        MetadataBadge(systemName: "flag", title: localizedString(note.importance.localizationKey), tint: .secondary)
                        MetadataBadge(systemName: "clock", title: formattedDateTime(note.updatedAt), tint: .secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            if !note.tags.isEmpty {
                Section(localizedAppText(for: settings.language, chinese: "标签", english: "Tags")) {
                    CompactTagStrip(tags: note.tags, limit: 99)
                        .padding(.vertical, 4)
                }
            }

            Section(localizedAppText(for: settings.language, chinese: "内容", english: "Content")) {
                MarkdownPreviewView(markdown: note.contentMd)
                    .padding(.vertical, 6)
            }

            if !note.relatedTasks.isEmpty {
                Section(localizedAppText(for: settings.language, chinese: "关联任务", english: "Related tasks")) {
                    ForEach(note.relatedTasks, id: \.id) { relatedTask in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(relatedTask.title)
                                .font(.body.weight(.medium))
                            HStack(spacing: 8) {
                                MetadataBadge(systemName: "flag", title: localizedString(relatedTask.priority.localizationKey), tint: .secondary)
                                if let dueAt = relatedTask.dueAt {
                                    MetadataBadge(systemName: "calendar", title: formattedDate(dueAt), tint: .secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .sageListChrome()
        .navigationTitle(localizedAppText(for: settings.language, chinese: "笔记详情", english: "Note"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.edit") {
                    showingEditor = true
                }
            }
        }
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
        .sheet(isPresented: $showingEditor) {
            NoteEditorSheet(note: note, tags: availableTags) { saved in
                note = saved
                onSave(saved)
            } onDelete: {
                onDelete()
                dismiss()
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let refreshed: NoteDTO = try await environment.apiClient.send(path: "/api/mobile/v1/notes/\(note.id)")
            note = refreshed
            onSave(refreshed)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func localizedString(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), locale: settings.locale)
    }

    private func formattedDate(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .omitted) ?? string
    }

    private func formattedDateTime(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .shortened) ?? string
    }
}

@MainActor
struct NoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let note: NoteDTO?
    let tags: [TagDTO]
    let onSave: (NoteDTO) -> Void
    let onDelete: (() -> Void)?

    @State private var title = ""
    @State private var summary = ""
    @State private var content = ""
    @State private var type: NoteType = .other
    @State private var importance: NoteImportance = .medium
    @State private var selectedTagIDs: Set<String> = []
    @State private var showingPreview = false

    init(note: NoteDTO?, tags: [TagDTO], onSave: @escaping (NoteDTO) -> Void, onDelete: (() -> Void)? = nil) {
        self.note = note
        self.tags = tags
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("notes.editor.meta") {
                        TextField("notes.editor.title", text: $title)
                        TextField("notes.editor.summary", text: $summary, axis: .vertical)
                            .lineLimit(2...4)
                        Picker("notes.type", selection: $type) {
                            ForEach(NoteType.allCases) { type in
                                Text(LocalizedStringKey(type.localizationKey)).tag(type)
                            }
                        }
                        Picker("notes.importance", selection: $importance) {
                            ForEach(NoteImportance.allCases) { importance in
                                Text(LocalizedStringKey(importance.localizationKey)).tag(importance)
                            }
                        }
                    }

                    if !tags.isEmpty {
                        Section("notes.tag") {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(tags) { tag in
                                        Button {
                                            if selectedTagIDs.contains(tag.id) {
                                                selectedTagIDs.remove(tag.id)
                                            } else {
                                                selectedTagIDs.insert(tag.id)
                                            }
                                        } label: {
                                            TagChipView(tag: tag)
                                                .opacity(selectedTagIDs.contains(tag.id) ? 1.0 : 0.45)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }

                    if note != nil {
                        Section {
                            Button(role: .destructive) {
                                Task { @MainActor in
                                    await delete()
                                }
                            } label: {
                                Label("common.delete", systemImage: "trash")
                            }
                        }
                    }
                }

                GlassSegmentedFilterRow(
                    items: [false, true],
                    title: { $0 ? "notes.preview" : "notes.source" },
                    selection: $showingPreview
                )
                .padding(.horizontal)

                if showingPreview {
                    ScrollView {
                        MarkdownPreviewView(markdown: content)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(.thinMaterial)
                } else {
                    TextEditor(text: $content)
                        .font(.body.monospaced())
                        .padding()
                        .background(.thinMaterial)
                }
            }
            .navigationTitle(note == nil ? LocalizedStringKey("notes.new") : LocalizedStringKey("notes.edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        Task { @MainActor in
                            await save()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                populate()
            }
            .onChange(of: title) { _, _ in persistDraft() }
            .onChange(of: summary) { _, _ in persistDraft() }
            .onChange(of: content) { _, _ in persistDraft() }
        }
    }

    private func populate() {
        let draftKey = note?.id ?? "new-note"
        if let note {
            title = note.title
            summary = note.summary
            content = note.contentMd
            type = note.type
            importance = note.importance
            selectedTagIDs = Set(note.tags.map(\.id))
        } else {
            restoreDraft(for: draftKey)
        }
    }

    private func persistDraft() {
        let snapshot = NoteDraftSnapshot(title: title, summary: summary, content: content)
        guard let data = try? JSONEncoder().encode(snapshot), let payload = String(data: data, encoding: .utf8) else { return }
        environment.draftStore.writeDraft(payload, for: note?.id ?? "new-note")
    }

    private func clearDraft() {
        environment.draftStore.clearDraft(for: note?.id ?? "new-note")
    }

    private func restoreDraft(for key: String) {
        let payload = environment.draftStore.readDraft(for: key)
        guard let data = payload.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(NoteDraftSnapshot.self, from: data)
        else {
            return
        }
        title = snapshot.title
        summary = snapshot.summary
        content = snapshot.content
    }

    private func save() async {
        let request = NoteWriteRequest(
            title: title,
            summary: summary,
            contentMd: content,
            type: type,
            importance: importance,
            isPinned: note?.isPinned ?? false,
            tagIds: Array(selectedTagIDs),
            relatedTaskIds: note?.relatedTasks.map(\.id) ?? []
        )

        do {
            let saved: NoteDTO
            if let note {
                saved = try await environment.apiClient.send(path: "/api/mobile/v1/notes/\(note.id)", method: "PATCH", body: request)
            } else {
                saved = try await environment.apiClient.send(path: "/api/mobile/v1/notes", method: "POST", body: request)
            }
            clearDraft()
            onSave(saved)
            dismiss()
        } catch {
        }
    }

    private func delete() async {
        guard let note else { return }
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(path: "/api/mobile/v1/notes/\(note.id)", method: "DELETE", body: EmptyBody())
            clearDraft()
            onDelete?()
            dismiss()
        } catch {
        }
    }
}

private struct NoteWriteRequest: Encodable {
    let title: String
    let summary: String
    let contentMd: String
    let type: NoteType
    let importance: NoteImportance
    let isPinned: Bool
    let tagIds: [String]
    let relatedTaskIds: [String]
}

private struct NoteDraftSnapshot: Codable {
    let title: String
    let summary: String
    let content: String
}
