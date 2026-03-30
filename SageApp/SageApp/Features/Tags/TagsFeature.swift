import SwiftUI
import Observation

@MainActor
@Observable
final class TagsViewModel {
    var tags: [TagDTO] = []
    var detail: TagDetailDTO?
    var isLoading = false
    var errorMessage: String?

    func load(using api: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            tags = try await api.send(path: "/api/mobile/v1/tags")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadDetail(tagRef: String, using api: APIClient) async {
        do {
            detail = try await api.send(path: "/api/mobile/v1/tags/\(tagRef)/detail")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct TagsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = TagsViewModel()
    @State private var editingTag: TagDTO?
    @State private var isCreatingTag = false

    var body: some View {
        List {
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
            } else if viewModel.tags.isEmpty {
                EmptyStateView(systemName: "tag", title: "tags.empty.title", message: "tags.empty.message")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.tags) { tag in
                    NavigationLink {
                        TagDetailView(tag: tag, availableTags: viewModel.tags)
                    } label: {
                        HStack {
                            Circle()
                                .fill(Color(hex: tag.color))
                                .frame(width: 12, height: 12)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(tag.name)
                                    .font(.body.weight(.semibold))
                                HStack(spacing: 8) {
                                    MetadataBadge(systemName: "checklist", title: "\(tag.taskCount ?? 0)", tint: .secondary)
                                    MetadataBadge(systemName: "note.text", title: "\(tag.noteCount ?? 0)", tint: .secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                    }
                    .sageListRowChrome()
                    .swipeActions {
                        Button {
                            editingTag = tag
                        } label: {
                            Label("common.edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .sageListChrome()
        .navigationTitle(localizedAppText(for: settings.language, chinese: "标签", english: "Tags"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isCreatingTag = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await viewModel.load(using: environment.apiClient)
        }
        .sheet(item: $editingTag) { tag in
            TagEditorSheet(tag: tag) {
                Task { @MainActor in
                    await viewModel.load(using: environment.apiClient)
                }
            }
        }
        .sheet(isPresented: $isCreatingTag) {
            TagEditorSheet(tag: nil) {
                Task { @MainActor in
                    await viewModel.load(using: environment.apiClient)
                }
            }
        }
    }
}

@MainActor
struct TagDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    let tag: TagDTO
    let availableTags: [TagDTO]
    @State private var viewModel = TagsViewModel()
    @State private var editingTag: TagDTO?

    var body: some View {
        List {
            if let detail = viewModel.detail {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        TagChipView(tag: detail.tag)
                        if let description = detail.tag.description {
                            Text(description)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .sageListRowChrome()
                }
                if !detail.tasks.isEmpty {
                    Section(localizedAppText(for: settings.language, chinese: "相关任务", english: "Related tasks")) {
                        ForEach(detail.tasks) { task in
                            NavigationLink {
                                TaskDetailView(task: task, availableTags: availableTags) { _ in } onDelete: { _ in }
                            } label: {
                                TaskListRowContent(task: task, language: settings.language, scheduledMinutes: 0)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !detail.notes.isEmpty {
                    Section(localizedAppText(for: settings.language, chinese: "相关笔记", english: "Related notes")) {
                        ForEach(detail.notes) { note in
                            NavigationLink {
                                NoteDetailView(note: note, availableTags: availableTags) { _ in } onDelete: {}
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(note.title)
                                        .font(.body.weight(.semibold))
                                    Text(note.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if viewModel.isLoading {
                LoadingStateView()
                    .listRowBackground(Color.clear)
            }
        }
        .sageListChrome()
        .navigationTitle(tag.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.edit") {
                    editingTag = tag
                }
            }
        }
        .task {
            await viewModel.loadDetail(tagRef: tag.id, using: environment.apiClient)
        }
        .sheet(item: $editingTag) { currentTag in
            TagEditorSheet(tag: currentTag) {
                Task { @MainActor in
                    await viewModel.loadDetail(tagRef: tag.id, using: environment.apiClient)
                }
            }
        }
    }
}

@MainActor
struct TagEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let tag: TagDTO?
    let onSave: () -> Void

    @State private var name = ""
    @State private var color = "#C96444"
    @State private var description = ""
    @State private var selectedColor = Color(hex: "#C96444")

    var body: some View {
        NavigationStack {
            Form {
                TextField("tags.editor.name", text: $name)
                ColorPicker("tags.editor.color", selection: Binding(
                    get: { selectedColor },
                    set: {
                        selectedColor = $0
                        color = $0.hexString
                    }
                ), supportsOpacity: false)
                HStack {
                    Text("tags.editor.color")
                    Spacer()
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedColor)
                        .frame(width: 44, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.2))
                        )
                }
                TextField("tags.editor.description", text: $description)
                if let tag {
                    Button(role: .destructive) {
                        Task { @MainActor in
                            await delete(tag: tag)
                        }
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(tag == nil ? LocalizedStringKey("tags.new") : LocalizedStringKey("tags.edit"))
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
                }
            }
            .task {
                if let tag {
                    name = tag.name
                    color = tag.color
                    selectedColor = Color(hex: tag.color)
                    description = tag.description ?? ""
                }
            }
        }
    }

    private func save() async {
        let request = TagWriteRequest(name: name, color: color, icon: nil, description: description.isEmpty ? nil : description, sortOrder: tag?.sortOrder)
        do {
            if let tag {
                let _: TagDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tags/\(tag.id)", method: "PATCH", body: request)
            } else {
                let _: TagDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tags", method: "POST", body: request)
            }
            onSave()
            dismiss()
        } catch {
        }
    }

    private func delete(tag: TagDTO) async {
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tags/\(tag.id)", method: "DELETE", body: EmptyBody())
            onSave()
            dismiss()
        } catch {
        }
    }
}

private struct TagWriteRequest: Encodable {
    let name: String
    let color: String
    let icon: String?
    let description: String?
    let sortOrder: Int?
}
