import SwiftUI
import Observation

enum TaskViewMode: String, CaseIterable, Hashable, Identifiable {
    case list
    case week
    case month

    var id: String { rawValue }
}

enum TaskStatusFilter: String, CaseIterable, Hashable, Identifiable {
    case all = "ALL"
    case todo = "TODO"
    case doing = "DOING"
    case done = "DONE"

    var id: String { rawValue }
}

enum TaskDueFilter: String, CaseIterable, Hashable, Identifiable {
    case all = "ALL"
    case today = "TODAY"
    case tomorrow = "TOMORROW"
    case thisWeek = "THIS_WEEK"
    case thisMonth = "THIS_MONTH"

    var id: String { rawValue }
}

@MainActor
@Observable
final class TasksViewModel {
    var tasks: [TaskDTO] = []
    var tags: [TagDTO] = []
    var isLoading = false
    var errorMessage: String?
    var viewMode: TaskViewMode = .list
    var statusFilter: TaskStatusFilter = .all
    var dueFilter: TaskDueFilter = .all

    func load(using api: APIClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let queryItems: [URLQueryItem] = [
                URLQueryItem(name: "status", value: statusFilter.rawValue),
                URLQueryItem(name: "due", value: viewMode == .list ? dueFilter.rawValue : nil)
            ].compactMap { $0.value == nil ? nil : $0 }

            let tasksPath = makeAPIPath("/api/mobile/v1/tasks", queryItems: queryItems)
            async let tasksRequest: [TaskDTO] = api.send(path: tasksPath)
            async let tagsRequest: [TagDTO] = api.send(path: "/api/mobile/v1/tags")
            tasks = try await tasksRequest
            tags = try await tagsRequest
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cycle(_ task: TaskDTO, using api: APIClient, notifications: NotificationScheduler) async {
        do {
            let updated: TaskDTO = try await api.send(path: "/api/mobile/v1/tasks/\(task.id)/cycle-status", method: "POST", body: EmptyBody())
            replace(updated)
            await notifications.scheduleReminder(for: updated)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ task: TaskDTO, using api: APIClient, notifications: NotificationScheduler) async {
        do {
            let _: EmptySuccessDTO = try await api.send(path: "/api/mobile/v1/tasks/\(task.id)", method: "DELETE", body: EmptyBody())
            tasks.removeAll { $0.id == task.id }
            await notifications.cancelReminder(for: task.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshTask(id: String, using api: APIClient) async {
        do {
            let refreshed: TaskDTO = try await api.send(path: "/api/mobile/v1/tasks/\(id)")
            replace(refreshed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSubtask(taskID: String, title: String, using api: APIClient) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        do {
            let _: SubTaskDTO = try await api.send(
                path: "/api/mobile/v1/tasks/\(taskID)/subtasks",
                method: "POST",
                body: NewSubtaskRequest(title: trimmedTitle)
            )
            await refreshTask(id: taskID, using: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func renameSubtask(taskID: String, subtask: SubTaskDTO, title: String, using api: APIClient) async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle != subtask.title else { return }

        do {
            let _: SubTaskDTO = try await api.send(
                path: "/api/mobile/v1/subtasks/\(subtask.id)",
                method: "PATCH",
                body: SubtaskPatchRequest(title: trimmedTitle, done: subtask.done, sortOrder: subtask.sortOrder)
            )
            await refreshTask(id: taskID, using: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleSubtask(taskID: String, subtask: SubTaskDTO, using api: APIClient) async {
        do {
            let _: SubTaskDTO = try await api.send(
                path: "/api/mobile/v1/subtasks/\(subtask.id)",
                method: "PATCH",
                body: SubtaskPatchRequest(title: subtask.title, done: !subtask.done, sortOrder: subtask.sortOrder)
            )
            await refreshTask(id: taskID, using: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteSubtask(taskID: String, subtaskID: String, using api: APIClient) async {
        do {
            let _: EmptySuccessDTO = try await api.send(
                path: "/api/mobile/v1/subtasks/\(subtaskID)",
                method: "DELETE",
                body: EmptyBody()
            )
            await refreshTask(id: taskID, using: api)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func replace(_ task: TaskDTO) {
        if let index = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[index] = task
        } else {
            tasks.insert(task, at: 0)
        }
    }
}

@MainActor
struct TasksView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = TasksViewModel()
    @State private var expandedTaskIDs: Set<String> = []
    @State private var activeSheet: TaskSheetDestination?

    var body: some View {
        List {
            Section {
                GlassSegmentedFilterRow(items: TaskViewMode.allCases, title: taskViewModeTitle, selection: $viewModel.viewMode)
                    .listRowBackground(Color.clear)
                GlassSegmentedFilterRow(items: TaskStatusFilter.allCases, title: taskStatusTitle, selection: $viewModel.statusFilter)
                    .listRowBackground(Color.clear)
                if viewModel.viewMode == .list {
                    GlassSegmentedFilterRow(items: TaskDueFilter.allCases, title: taskDueTitle, selection: $viewModel.dueFilter)
                        .listRowBackground(Color.clear)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage, retry: {
                    Task { @MainActor in
                        await reload()
                    }
                })
                .listRowBackground(Color.clear)
            } else if viewModel.isLoading {
                LoadingStateView()
                    .listRowBackground(Color.clear)
            } else if filteredTasks.isEmpty {
                EmptyStateView(systemName: "checklist", title: "tasks.empty.title", message: "tasks.empty.message")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(groupedTasks, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.tasks) { task in
                            ExpandableTaskCard(
                                task: task,
                                language: environment.settings.language,
                                isExpanded: expandedTaskIDs.contains(task.id),
                                onToggleExpand: {
                                    toggleExpansion(task.id)
                                },
                                onEdit: {
                                    activeSheet = .detail(task)
                                },
                                onCycle: {
                                    Task { @MainActor in
                                        await viewModel.cycle(task, using: environment.apiClient, notifications: environment.notificationScheduler)
                                    }
                                },
                                onCreateSubtask: { title in
                                    Task { @MainActor in
                                        await viewModel.createSubtask(taskID: task.id, title: title, using: environment.apiClient)
                                    }
                                },
                                onRenameSubtask: { subtask, title in
                                    Task { @MainActor in
                                        await viewModel.renameSubtask(taskID: task.id, subtask: subtask, title: title, using: environment.apiClient)
                                    }
                                },
                                onToggleSubtask: { subtask in
                                    Task { @MainActor in
                                        await viewModel.toggleSubtask(taskID: task.id, subtask: subtask, using: environment.apiClient)
                                    }
                                },
                                onDeleteSubtask: { subtask in
                                    Task { @MainActor in
                                        await viewModel.deleteSubtask(taskID: task.id, subtaskID: subtask.id, using: environment.apiClient)
                                    }
                                }
                            )
                            .sageListRowChrome()
                            .swipeActions {
                                Button(role: .destructive) {
                                    Task { @MainActor in
                                        expandedTaskIDs.remove(task.id)
                                        await viewModel.delete(task, using: environment.apiClient, notifications: environment.notificationScheduler)
                                    }
                                } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .sageListChrome()
        .navigationTitle(localizedAppText(for: settings.language, chinese: "任务", english: "Tasks"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    activeSheet = .create
                } label: {
                    Label("tasks.new", systemImage: "plus")
                }
            }
        }
        .task {
            await reload()
        }
        .onChange(of: viewModel.viewMode) { _, _ in
            Task { @MainActor in
                await reload()
            }
        }
        .onChange(of: viewModel.statusFilter) { _, _ in
            Task { @MainActor in
                await reload()
            }
        }
        .onChange(of: viewModel.dueFilter) { _, _ in
            Task { @MainActor in
                await reload()
            }
        }
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .create:
                TaskEditorSheet(task: nil, tags: viewModel.tags) { created in
                    viewModel.replace(created)
                }
            case let .detail(task):
                TaskEditorSheet(task: task, tags: viewModel.tags) { updated in
                    viewModel.replace(updated)
                }
            }
        }
        .refreshable {
            await reload()
        }
    }

    private var filteredTasks: [TaskDTO] {
        viewModel.tasks
    }

    private var sortedTasks: [TaskDTO] {
        filteredTasks.sorted(by: taskComesFirst)
    }

    private var groupedTasks: [TaskGroup] {
        switch viewModel.viewMode {
        case .list:
            return [TaskGroup(title: localizedTasksText(chinese: "全部任务", english: "All Tasks"), tasks: sortedTasks)]
        case .week:
            return Dictionary(grouping: sortedTasks) { task in
                weekSectionTitle(for: taskSortDate(task))
            }
            .map { TaskGroup(title: $0.key, tasks: $0.value.sorted(by: taskComesFirst)) }
            .sorted(by: groupComesFirst)
        case .month:
            return Dictionary(grouping: sortedTasks) { task in
                monthSectionTitle(for: taskSortDate(task))
            }
            .map { TaskGroup(title: $0.key, tasks: $0.value.sorted(by: taskComesFirst)) }
            .sorted(by: groupComesFirst)
        }
    }

    private func reload() async {
        await viewModel.load(using: environment.apiClient)
    }

    private func toggleExpansion(_ taskID: String) {
        if expandedTaskIDs.contains(taskID) {
            expandedTaskIDs.remove(taskID)
        } else {
            expandedTaskIDs.insert(taskID)
        }
    }

    private func taskViewModeTitle(_ mode: TaskViewMode) -> LocalizedStringKey {
        switch mode {
        case .list: return "tasks.view.list"
        case .week: return "tasks.view.week"
        case .month: return "tasks.view.month"
        }
    }

    private func taskStatusTitle(_ filter: TaskStatusFilter) -> LocalizedStringKey {
        switch filter {
        case .all: return "tasks.filter.all"
        case .todo: return "tasks.filter.todo"
        case .doing: return "tasks.filter.doing"
        case .done: return "tasks.filter.done"
        }
    }

    private func taskDueTitle(_ filter: TaskDueFilter) -> LocalizedStringKey {
        switch filter {
        case .all: return "tasks.filter.all"
        case .today: return "tasks.due.today"
        case .tomorrow: return "tasks.due.tomorrow"
        case .thisWeek: return "tasks.due.thisWeek"
        case .thisMonth: return "tasks.due.thisMonth"
        }
    }

    private func weekSectionTitle(for date: Date?) -> String {
        guard let date else { return localizedTasksText(chinese: "未安排", english: "Unscheduled") }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func monthSectionTitle(for date: Date?) -> String {
        guard let date else { return localizedTasksText(chinese: "未安排", english: "Unscheduled") }
        return date.formatted(.dateTime.month(.wide))
    }

    private func taskSortDate(_ task: TaskDTO) -> Date? {
        Date.fromISO8601(task.dueAt)
    }

    private func taskComesFirst(_ lhs: TaskDTO, _ rhs: TaskDTO) -> Bool {
        let lhsDate = taskSortDate(lhs)
        let rhsDate = taskSortDate(rhs)

        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.createdAt < rhs.createdAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func groupComesFirst(_ lhs: TaskGroup, _ rhs: TaskGroup) -> Bool {
        let lhsDate = lhs.tasks.compactMap(taskSortDate).min()
        let rhsDate = rhs.tasks.compactMap(taskSortDate).min()

        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.title < rhs.title
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.title < rhs.title
        }
    }

    private func localizedTasksText(chinese: String, english: String) -> String {
        localizedAppText(for: environment.settings.language, chinese: chinese, english: english)
    }
}

private enum TaskSheetDestination: Identifiable {
    case create
    case detail(TaskDTO)

    var id: String {
        switch self {
        case .create:
            return "create"
        case let .detail(task):
            return task.id
        }
    }
}

@MainActor
private struct ExpandableTaskCard: View {
    let task: TaskDTO
    let language: AppLanguage
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onEdit: () -> Void
    let onCycle: () -> Void
    let onCreateSubtask: (String) -> Void
    let onRenameSubtask: (SubTaskDTO, String) -> Void
    let onToggleSubtask: (SubTaskDTO) -> Void
    let onDeleteSubtask: (SubTaskDTO) -> Void

    @State private var newSubtaskTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onCycle) {
                    Image(systemName: statusSymbol)
                        .font(.headline)
                        .foregroundStyle(statusColor)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(task.title)
                            .font(.body.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .strikethrough(task.status == .done)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        if let dueAt = task.dueAt {
                            TaskMetaBadge(systemName: "calendar", title: formattedDate(dueAt))
                        }
                        TaskMetaBadge(
                            systemName: "line.3.horizontal.decrease.circle",
                            title: localizedAppText(
                                for: language,
                                chinese: task.status == .done ? "已完成" : task.status == .doing ? "进行中" : "待办",
                                english: task.status == .done ? "Done" : task.status == .doing ? "Doing" : "Todo"
                            )
                        )
                        TaskMetaBadge(
                            systemName: "list.bullet",
                            title: subtaskCountLabel
                        )
                    }
                    .transaction { transaction in
                        transaction.animation = nil
                    }

                    if !task.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(task.tags) { tag in
                                    TagChipView(tag: tag)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .animation(nil, value: isExpanded)

                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.regularMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.16))
                        )
                }
                .buttonStyle(.plain)
            }
            .contentShape(Rectangle())
            .transaction { transaction in
                transaction.animation = nil
            }
            .onTapGesture {
                onToggleExpand()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()

                    if task.subtasks.isEmpty {
                        Text(localizedAppText(for: language, chinese: "还没有子任务，直接在下面添加。", english: "No subtasks yet. Add one below."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(task.subtasks.sorted(by: subtaskComesFirst)) { subtask in
                            InlineSubtaskRow(
                                subtask: subtask,
                                language: language,
                                onCommitTitle: { title in
                                    onRenameSubtask(subtask, title)
                                },
                                onToggle: {
                                    onToggleSubtask(subtask)
                                },
                                onDelete: {
                                    onDeleteSubtask(subtask)
                                }
                            )
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.orange)

                        TextField(
                            localizedAppText(for: language, chinese: "添加子任务", english: "Add subtask"),
                            text: $newSubtaskTitle
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSubtask)

                        Button("common.add") {
                            addSubtask()
                        }
                        .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(.top, 12)
                .padding(.leading, 40)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous))
    }

    private var statusSymbol: String {
        switch task.status {
        case .todo, .inbox:
            return "circle"
        case .doing:
            return "circle.dashed"
        case .done:
            return "checkmark.circle.fill"
        case .archived:
            return "archivebox"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .done:
            return .green
        case .doing:
            return .orange
        default:
            return .secondary
        }
    }

    private var subtaskCountLabel: String {
        localizedAppText(
            for: language,
            chinese: "\(task.subtasks.count) 个子任务",
            english: "\(task.subtasks.count) subtasks"
        )
    }

    private func formattedDate(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .omitted) ?? string
    }

    private func subtaskComesFirst(_ lhs: SubTaskDTO, _ rhs: SubTaskDTO) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func addSubtask() {
        let title = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        onCreateSubtask(title)
        newSubtaskTitle = ""
    }
}

@MainActor
private struct InlineSubtaskRow: View {
    let subtask: SubTaskDTO
    let language: AppLanguage
    let onCommitTitle: (String) -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var draftTitle: String

    init(
        subtask: SubTaskDTO,
        language: AppLanguage,
        onCommitTitle: @escaping (String) -> Void,
        onToggle: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.subtask = subtask
        self.language = language
        self.onCommitTitle = onCommitTitle
        self.onToggle = onToggle
        self.onDelete = onDelete
        _draftTitle = State(initialValue: subtask.title)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(subtask.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            TextField(localizedAppText(for: language, chinese: "子任务标题", english: "Subtask title"), text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .strikethrough(subtask.done)
                .onSubmit(commitIfNeeded)

            if needsSave {
                Button("common.save") {
                    commitIfNeeded()
                }
                .font(.caption.weight(.semibold))
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .onChange(of: subtask.title) { _, newValue in
            if newValue != draftTitle {
                draftTitle = newValue
            }
        }
    }

    private var needsSave: Bool {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != subtask.title
    }

    private func commitIfNeeded() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftTitle = subtask.title
            return
        }
        onCommitTitle(trimmed)
    }
}

@MainActor
struct TaskRow: View {
    let task: TaskDTO
    let cycle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: cycle) {
                Image(systemName: statusSymbol)
                    .font(.headline)
                    .foregroundStyle(statusColor)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(task.title)
                    .font(.body.weight(.medium))
                    .strikethrough(task.status == .done)
                HStack(spacing: 8) {
                    if let dueAt = task.dueAt {
                        Label(formattedDate(dueAt), systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reminderAt = task.reminderAt {
                        Label(formattedTime(reminderAt), systemImage: "bell")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let estimateMinutes = task.estimateMinutes {
                        Label("\(estimateMinutes)m", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !task.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(task.tags) { tag in
                                TagChipView(tag: tag)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var statusSymbol: String {
        switch task.status {
        case .todo, .inbox:
            return "circle"
        case .doing:
            return "circle.dashed"
        case .done:
            return "checkmark.circle.fill"
        case .archived:
            return "archivebox"
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .done:
            return .green
        case .doing:
            return .orange
        default:
            return .secondary
        }
    }

    private func formattedDate(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .omitted) ?? string
    }

    private func formattedTime(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .omitted, time: .shortened) ?? string
    }
}

private struct TaskMetaBadge: View {
    let systemName: String
    let title: String

    var body: some View {
        Label(title, systemImage: systemName)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct TaskGroup: Hashable {
    let title: String
    let tasks: [TaskDTO]
}

private enum TaskEditorMode {
    case view
    case edit
}

@MainActor
struct TaskEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let task: TaskDTO?
    let tags: [TagDTO]
    let onSave: (TaskDTO) -> Void

    @State private var mode: TaskEditorMode
    @State private var loadedTask: TaskDTO?
    @State private var availableTags: [TagDTO]
    @State private var title = ""
    @State private var details = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .medium
    @State private var dueAt: Date = .now
    @State private var hasDueDate = false
    @State private var reminderAt: Date = .now
    @State private var hasReminder = false
    @State private var estimateMinutes = ""
    @State private var selectedTagIDs: Set<String> = []
    @State private var blocks: [TimeBlockDTO] = []
    @State private var editingBlock: TimeBlockDTO?
    @State private var placementContext: TimelinePlacementContext?
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(task: TaskDTO?, tags: [TagDTO], onSave: @escaping (TaskDTO) -> Void) {
        self.task = task
        self.tags = tags
        self.onSave = onSave
        _mode = State(initialValue: task == nil ? .edit : .view)
        _availableTags = State(initialValue: tags)
    }

    var body: some View {
        NavigationStack {
            List {
                if mode == .view, let currentTask {
                    taskOverview(currentTask)
                } else {
                    editorContent
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .sageListChrome()
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(
                            localizedAppText(
                                for: environment.settings.language,
                                chinese: mode == .view ? "关闭" : "取消",
                                english: mode == .view ? "Close" : "Cancel"
                            )
                        )
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if task != nil, mode == .view {
                        Button("common.edit") {
                            mode = .edit
                        }
                    } else {
                        Button("common.save") {
                            Task { @MainActor in
                                await save()
                            }
                        }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    }
                }
            }
            .task {
                await loadReferenceData()
            }
            .sheet(item: $editingBlock) { block in
                TimeBlockEditorSheet(task: currentTask, existing: block) { _ in
                    Task { @MainActor in
                        await loadReferenceData()
                    }
                } onDelete: {
                    Task { @MainActor in
                        await loadReferenceData()
                    }
                }
            }
            .sheet(item: $placementContext) { context in
                TimelinePlacementSheet(context: context) { _ in
                    Task { @MainActor in
                        await loadReferenceData()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentTask: TaskDTO? {
        loadedTask ?? task
    }

    private var navigationTitle: LocalizedStringKey {
        if task == nil {
            return "tasks.new"
        }
        return mode == .view ? "tasks.title" : "tasks.edit"
    }

    @ViewBuilder
    private func taskOverview(_ task: TaskDTO) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(task.title)
                    .font(.title3.weight(.bold))
                if let description = task.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }

        Section {
            detailRow(title: localizedAppText(for: environment.settings.language, chinese: "状态", english: "Status"), value: localizedStatus(task.status))
            detailRow(title: localizedAppText(for: environment.settings.language, chinese: "优先级", english: "Priority"), value: localizedPriority(task.priority))
            if let dueAt = task.dueAt {
                detailRow(title: localizedAppText(for: environment.settings.language, chinese: "截止时间", english: "Due"), value: formattedDateTime(dueAt))
            }
            if let reminderAt = task.reminderAt {
                detailRow(title: localizedAppText(for: environment.settings.language, chinese: "提醒", english: "Reminder"), value: formattedDateTime(reminderAt))
            }
            if let estimateMinutes = task.estimateMinutes {
                detailRow(title: localizedAppText(for: environment.settings.language, chinese: "预估", english: "Estimate"), value: "\(estimateMinutes)m")
            }
        }

        if !task.tags.isEmpty {
            Section(localizedAppText(for: environment.settings.language, chinese: "标签", english: "Tags")) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(task.tags) { tag in
                            TagChipView(tag: tag)
                        }
                    }
                }
            }
        }

        Section(localizedAppText(for: environment.settings.language, chinese: "子任务", english: "Subtasks")) {
            if task.subtasks.isEmpty {
                Text(localizedAppText(for: environment.settings.language, chinese: "子任务请在任务列表展开区中维护。", english: "Manage subtasks from the expanded task card."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(task.subtasks.sorted(by: subtaskComesFirst)) { subtask in
                    HStack(spacing: 10) {
                        Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.done ? .green : .secondary)
                        Text(subtask.title)
                            .strikethrough(subtask.done)
                    }
                }
            }
        }

        Section("timeline.title") {
            if task.timeBlocks?.isEmpty ?? blocks.isEmpty {
                Text(localizedAppText(for: environment.settings.language, chinese: "还没有日程或部署。", english: "No schedule blocks yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedBlocks, id: \.id) { block in
                    timeBlockSummary(block)
                }
            }
        }
    }

    @ViewBuilder
    private var editorContent: some View {
        Section("tasks.editor.details") {
            TextField("tasks.editor.title", text: $title)
            TextField("tasks.editor.description", text: $details, axis: .vertical)
                .lineLimit(2...6)

            Picker("tasks.editor.status", selection: $status) {
                ForEach([TaskStatus.todo, .doing, .done], id: \.self) { status in
                    Text(LocalizedStringKey(status.localizationKey)).tag(status)
                }
            }

            Picker("tasks.editor.priority", selection: $priority) {
                ForEach(TaskPriority.allCases, id: \.self) { priority in
                    Text(LocalizedStringKey(priority.localizationKey)).tag(priority)
                }
            }

            Toggle("tasks.editor.hasDueDate", isOn: $hasDueDate.animation())
            if hasDueDate {
                DatePicker("tasks.editor.dueAt", selection: $dueAt)
            }

            Toggle("tasks.editor.hasReminder", isOn: $hasReminder.animation())
            if hasReminder {
                DatePicker("tasks.editor.reminderAt", selection: $reminderAt)
            }

            TextField("tasks.editor.estimate", text: $estimateMinutes)
                .keyboardType(.numberPad)
        }

        if !availableTags.isEmpty {
            Section("tasks.editor.tags") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableTags) { tag in
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

        Section("timeline.title") {
            if blocks.isEmpty {
                Text(localizedAppText(for: environment.settings.language, chinese: "还没有日程或部署。", english: "No schedule blocks yet."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedBlocks, id: \.id) { block in
                    Button {
                        editingBlock = block
                    } label: {
                        timeBlockSummary(block)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                guard let currentTask else { return }
                placementContext = TimelinePlacementContext(
                    availableTasks: [currentTask],
                    preselectedTaskID: currentTask.id,
                    preselectedDate: Date.fromISO8601(currentTask.dueAt) ?? .now,
                    preferredMode: .timed,
                    lockedSubTaskId: nil,
                    lockTaskSelection: true,
                    lockDeploymentTargetSelection: false
                )
            } label: {
                Label("timeline.addBlock", systemImage: "calendar.badge.plus")
            }
            .disabled(currentTask == nil)
        }
    }

    private func loadReferenceData() async {
        do {
            let fetchedTags: [TagDTO] = try await environment.apiClient.send(path: "/api/mobile/v1/tags")
            availableTags = fetchedTags

            if let task {
                let fetchedTask: TaskDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(task.id)")
                loadedTask = fetchedTask
                populate(with: fetchedTask)
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        if task == nil && availableTags.isEmpty {
            availableTags = tags
        }
    }

    private func populate(with task: TaskDTO) {
        title = task.title
        details = task.description ?? ""
        status = task.status
        priority = task.priority
        if let due = Date.fromISO8601(task.dueAt) {
            dueAt = due
            hasDueDate = true
        } else {
            hasDueDate = false
        }
        if let reminder = Date.fromISO8601(task.reminderAt) {
            reminderAt = reminder
            hasReminder = true
        } else {
            hasReminder = false
        }
        estimateMinutes = task.estimateMinutes.map(String.init) ?? ""
        selectedTagIDs = Set(task.tags.map(\.id))
        blocks = task.timeBlocks ?? []
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let request = TaskWriteRequest(
            title: title,
            description: details.isEmpty ? nil : details,
            status: status,
            priority: priority,
            dueAt: hasDueDate ? DateFormatter.makeOffsetISO8601().string(from: dueAt) : nil,
            reminderAt: hasReminder ? DateFormatter.makeOffsetISO8601().string(from: reminderAt) : nil,
            estimateMinutes: Int(estimateMinutes),
            isPinned: currentTask?.isPinned ?? false,
            tagIds: Array(selectedTagIDs)
        )

        do {
            let savedTask: TaskDTO
            if let currentTask {
                savedTask = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(currentTask.id)", method: "PATCH", body: request)
            } else {
                savedTask = try await environment.apiClient.send(path: "/api/mobile/v1/tasks", method: "POST", body: request)
            }

            let refreshed: TaskDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(savedTask.id)")
            loadedTask = refreshed
            populate(with: refreshed)
            onSave(refreshed)
            await environment.notificationScheduler.scheduleReminder(for: refreshed)
            errorMessage = nil

            if task == nil {
                dismiss()
            } else {
                mode = .view
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var sortedBlocks: [TimeBlockDTO] {
        blocks.sorted(by: blockComesFirst)
    }

    private func timeBlockSummary(_ block: TimeBlockDTO) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(blockTitle(block))
                .font(.body.weight(.semibold))
            Text(blockSubtitle(block))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func localizedStatus(_ status: TaskStatus) -> String {
        localizedAppText(
            for: environment.settings.language,
            chinese: status == .done ? "已完成" : status == .doing ? "进行中" : status == .inbox ? "收件箱" : status == .archived ? "已归档" : "待办",
            english: status == .done ? "Done" : status == .doing ? "Doing" : status == .inbox ? "Inbox" : status == .archived ? "Archived" : "Todo"
        )
    }

    private func localizedPriority(_ priority: TaskPriority) -> String {
        switch priority {
        case .low:
            return localizedAppText(for: environment.settings.language, chinese: "低", english: "Low")
        case .medium:
            return localizedAppText(for: environment.settings.language, chinese: "中", english: "Medium")
        case .high:
            return localizedAppText(for: environment.settings.language, chinese: "高", english: "High")
        case .urgent:
            return localizedAppText(for: environment.settings.language, chinese: "紧急", english: "Urgent")
        }
    }

    private func formattedDateTime(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .shortened) ?? string
    }

    private func subtaskComesFirst(_ lhs: SubTaskDTO, _ rhs: SubTaskDTO) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.createdAt < rhs.createdAt
    }

    private func blockComesFirst(_ lhs: TimeBlockDTO, _ rhs: TimeBlockDTO) -> Bool {
        let lhsDate = Date.fromISO8601(lhs.startAt)
        let rhsDate = Date.fromISO8601(rhs.startAt)

        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.createdAt < rhs.createdAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func blockTitle(_ block: TimeBlockDTO) -> String {
        deploymentTargetTitle(for: currentTask, subTaskId: block.subTaskId, language: environment.settings.language)
    }

    private func blockSubtitle(_ block: TimeBlockDTO) -> String {
        if block.isAllDay {
            let mode = block.originTimeBlockId == nil
                ? localizedAppText(for: environment.settings.language, chinese: "手动部署", english: "Manual assignment")
                : localizedAppText(for: environment.settings.language, chinese: "自动同步部署", english: "Auto assignment")
            return "\(formattedDateTime(block.startAt)) · \(mode)"
        }

        return "\(formattedDateTime(block.startAt)) - \(Date.fromISO8601(block.endAt)?.formatted(date: .omitted, time: .shortened) ?? block.endAt)"
    }
}

@MainActor
struct TimeBlockEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let task: TaskDTO?
    let existing: TimeBlockDTO
    let onSave: (TimeBlockDTO) -> Void
    let onDelete: (() -> Void)?

    @State private var startAt = Date.now
    @State private var endAt = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var isAllDay = false
    @State private var errorMessage: String?

    init(task: TaskDTO?, existing: TimeBlockDTO, onSave: @escaping (TimeBlockDTO) -> Void, onDelete: (() -> Void)? = nil) {
        self.task = task
        self.existing = existing
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("timeline.start", selection: $startAt, displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                if !isAllDay {
                    DatePicker("timeline.end", selection: $endAt)
                }
                Toggle("timeline.allDay", isOn: $isAllDay)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                Button(role: .destructive) {
                    Task { @MainActor in
                        await delete()
                    }
                } label: {
                    Label("common.delete", systemImage: "trash")
                }
            }
            .navigationTitle("timeline.editBlock")
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
                startAt = Date.fromISO8601(existing.startAt) ?? startAt
                endAt = Date.fromISO8601(existing.endAt) ?? endAt
                isAllDay = existing.isAllDay
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        do {
            let adjustedEndAt = isAllDay
                ? Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: startAt)) ?? endAt
                : max(endAt, Calendar.current.date(byAdding: .minute, value: 30, to: startAt) ?? endAt)

            let request = TimeBlockWriteRequest(
                startAt: DateFormatter.makeOffsetISO8601().string(from: isAllDay ? Calendar.current.startOfDay(for: startAt) : startAt),
                endAt: DateFormatter.makeOffsetISO8601().string(from: adjustedEndAt),
                subTaskId: existing.subTaskId,
                isAllDay: isAllDay
            )

            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(existing.id)",
                method: "PATCH",
                body: request
            )
            onSave(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(existing.id)",
                method: "DELETE",
                body: EmptyBody()
            )
            onDelete?()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum TimelinePlacementMode: String, CaseIterable, Identifiable {
    case timed
    case assignment

    var id: String { rawValue }
}

struct TimelinePlacementContext: Identifiable {
    let id = UUID()
    let availableTasks: [TaskDTO]
    let preselectedTaskID: String?
    let preselectedDate: Date
    let preferredMode: TimelinePlacementMode
    let lockedSubTaskId: String?
    let lockTaskSelection: Bool
    let lockDeploymentTargetSelection: Bool
}

struct DeploymentTargetOption: Hashable, Identifiable {
    let id: String
    let title: String
    let subTaskId: String?
}

@MainActor
struct TimelinePlacementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let context: TimelinePlacementContext
    let onSaved: (TimeBlockDTO) -> Void

    @State private var selectedTaskID: String
    @State private var selectedMode: TimelinePlacementMode
    @State private var selectedDay: Date
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var selectedSubTaskId: String?
    @State private var errorMessage: String?

    init(context: TimelinePlacementContext, onSaved: @escaping (TimeBlockDTO) -> Void) {
        self.context = context
        self.onSaved = onSaved

        let defaultTaskID = context.preselectedTaskID ?? context.availableTasks.first?.id ?? ""
        let start = Calendar.current.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: context.preselectedDate
        ) ?? context.preselectedDate
        let end = Calendar.current.date(byAdding: .hour, value: 1, to: start) ?? start

        _selectedTaskID = State(initialValue: defaultTaskID)
        _selectedMode = State(initialValue: context.preferredMode)
        _selectedDay = State(initialValue: context.preselectedDate)
        _startAt = State(initialValue: start)
        _endAt = State(initialValue: end)
        _selectedSubTaskId = State(initialValue: context.lockedSubTaskId)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !context.lockTaskSelection && context.availableTasks.count > 1 {
                    Picker(selection: $selectedTaskID) {
                        ForEach(context.availableTasks) { task in
                            Text(task.title).tag(task.id)
                        }
                    } label: {
                        Text(localizedAppText(for: environment.settings.language, chinese: "任务", english: "Task"))
                    }
                } else if let selectedTask {
                    Section(localizedAppText(for: environment.settings.language, chinese: "任务", english: "Task")) {
                        Text(selectedTask.title)
                    }
                }

                Picker(selection: $selectedMode) {
                    Text(localizedAppText(for: environment.settings.language, chinese: "安排时间", english: "Timed block"))
                        .tag(TimelinePlacementMode.timed)
                    Text(localizedAppText(for: environment.settings.language, chinese: "加入待部署区", english: "Assignment"))
                        .tag(TimelinePlacementMode.assignment)
                } label: {
                    Text(localizedAppText(for: environment.settings.language, chinese: "类型", english: "Type"))
                }
                .disabled(context.preferredMode == .assignment && context.lockTaskSelection)

                if let selectedTask, !deploymentOptions(for: selectedTask, language: environment.settings.language).isEmpty {
                    Section(localizedAppText(for: environment.settings.language, chinese: "部署对象", english: "Deployment target")) {
                        if context.lockDeploymentTargetSelection {
                            Text(deploymentTargetTitle(for: selectedTask, subTaskId: selectedSubTaskId, language: environment.settings.language))
                        } else {
                            ForEach(deploymentOptions(for: selectedTask, language: environment.settings.language)) { option in
                                Button {
                                    selectedSubTaskId = option.subTaskId
                                } label: {
                                    HStack {
                                        Text(option.title)
                                        Spacer()
                                        if selectedSubTaskId == option.subTaskId {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section(localizedAppText(for: environment.settings.language, chinese: "日期", english: "Date")) {
                    DatePicker(
                        localizedAppText(for: environment.settings.language, chinese: "日期", english: "Date"),
                        selection: $selectedDay,
                        displayedComponents: [.date]
                    )

                    if selectedMode == .timed {
                        DatePicker("timeline.start", selection: $startAt, displayedComponents: [.hourAndMinute, .date])
                        DatePicker("timeline.end", selection: $endAt, displayedComponents: [.hourAndMinute, .date])
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(selectedMode == .timed ? LocalizedStringKey("timeline.addBlock") : LocalizedStringKey("timeline.allDay"))
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
                    .disabled(selectedTask == nil)
                }
            }
            .onChange(of: selectedTaskID) { _, _ in
                guard let selectedTask else { return }
                if context.lockDeploymentTargetSelection {
                    return
                }
                let validSubtaskIDs = Set(selectedTask.subtasks.map(\.id))
                if let selectedSubTaskId, !validSubtaskIDs.contains(selectedSubTaskId) {
                    self.selectedSubTaskId = nil
                }
            }
            .onChange(of: selectedDay) { _, newValue in
                startAt = merged(day: newValue, time: startAt)
                endAt = merged(day: newValue, time: endAt)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var selectedTask: TaskDTO? {
        context.availableTasks.first(where: { $0.id == selectedTaskID })
    }

    private func save() async {
        guard let selectedTask else { return }

        let startDate: Date
        let endDate: Date

        if selectedMode == .assignment {
            startDate = Calendar.current.startOfDay(for: selectedDay)
            endDate = Calendar.current.date(byAdding: .day, value: 1, to: startDate) ?? startDate
        } else {
            startDate = merged(day: selectedDay, time: startAt)
            endDate = merged(day: selectedDay, time: max(endAt, Calendar.current.date(byAdding: .minute, value: 30, to: startDate) ?? endAt))
        }

        guard endDate > startDate else {
            errorMessage = localizedAppText(for: environment.settings.language, chinese: "结束时间必须晚于开始时间。", english: "End time must be later than start time.")
            return
        }

        do {
            let request = TimeBlockWriteRequest(
                startAt: DateFormatter.makeOffsetISO8601().string(from: startDate),
                endAt: DateFormatter.makeOffsetISO8601().string(from: endDate),
                subTaskId: selectedSubTaskId,
                isAllDay: selectedMode == .assignment
            )

            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/tasks/\(selectedTask.id)/time-blocks",
                method: "POST",
                body: request
            )
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func merged(day: Date, time: Date) -> Date {
        let calendar = Calendar.current
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let timeComponents = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.date(from: DateComponents(
            year: dayComponents.year,
            month: dayComponents.month,
            day: dayComponents.day,
            hour: timeComponents.hour,
            minute: timeComponents.minute
        )) ?? day
    }
}

private struct TaskWriteRequest: Encodable {
    let title: String
    let description: String?
    let status: TaskStatus
    let priority: TaskPriority
    let dueAt: String?
    let reminderAt: String?
    let estimateMinutes: Int?
    let isPinned: Bool
    let tagIds: [String]
}

struct TimeBlockWriteRequest: Encodable {
    let startAt: String
    let endAt: String
    let subTaskId: String?
    let isAllDay: Bool
}

private struct NewSubtaskRequest: Encodable {
    let title: String
}

private struct SubtaskPatchRequest: Encodable {
    let title: String
    let done: Bool
    let sortOrder: Int
}

func localizedAppText(for language: AppLanguage, chinese: String, english: String) -> String {
    language == .chineseSimplified ? chinese : english
}

func deploymentOptions(for task: TaskDTO, language: AppLanguage) -> [DeploymentTargetOption] {
    let primaryTitle = localizedAppText(for: language, chinese: "主任务", english: "Main task")
    return [DeploymentTargetOption(id: "task", title: primaryTitle, subTaskId: nil)]
        + task.subtasks
            .sorted { lhs, rhs in
                if lhs.sortOrder != rhs.sortOrder {
                    return lhs.sortOrder < rhs.sortOrder
                }
                return lhs.createdAt < rhs.createdAt
            }
            .map { subtask in
                DeploymentTargetOption(id: subtask.id, title: subtask.title, subTaskId: subtask.id)
            }
}

func deploymentTargetTitle(for task: TaskDTO?, subTaskId: String?, language: AppLanguage) -> String {
    guard let task else {
        return localizedAppText(for: language, chinese: "主任务", english: "Main task")
    }

    if let subTaskId, let subtask = task.subtasks.first(where: { $0.id == subTaskId }) {
        return subtask.title
    }

    return localizedAppText(for: language, chinese: "主任务", english: "Main task")
}

extension DateFormatter {
    static func makeOffsetISO8601() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }
}
