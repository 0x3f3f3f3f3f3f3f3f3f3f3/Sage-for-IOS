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

enum TaskPrimaryFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case todo
    case doing
    case done

    var id: String { rawValue }
}

private struct TaskAdvancedFilterState: Equatable {
    var query = ""
    var dueFilter: TaskDueFilter = .all
    var selectedTagIDs: Set<String> = []

    var hasActiveFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dueFilter != .all || !selectedTagIDs.isEmpty
    }
}

private struct TaskHomeSection: Identifiable, Hashable {
    let id: String
    let title: String
    let tasks: [TaskDTO]
}

private enum TaskQuickFocus: String, Hashable {
    case today
    case planned
    case overdue
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
            async let tasksRequest: [TaskDTO] = api.send(path: "/api/mobile/v1/tasks")
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
    @State private var primaryFilter: TaskPrimaryFilter = .all
    @State private var advancedFilters = TaskAdvancedFilterState()
    @State private var activeSheet: TaskSheetDestination?
    @State private var placementContext: TimelinePlacementContext?
    @State private var showingFilters = false
    @State private var showingCompletedSection = false
    @State private var quickFocus: TaskQuickFocus?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        summaryStatChip(
                            title: "\(todayCount) \(localizedTasksText(chinese: "今天", english: "Today"))",
                            isActive: quickFocus == .today
                        ) {
                            quickFocus = quickFocus == .today ? nil : .today
                        }

                        summaryStatChip(
                            title: "\(plannedCount) \(localizedTasksText(chinese: "已规划", english: "Planned"))",
                            isActive: quickFocus == .planned,
                            tint: .blue
                        ) {
                            quickFocus = quickFocus == .planned ? nil : .planned
                        }

                        summaryStatChip(
                            title: "\(overdueCount) \(localizedTasksText(chinese: "逾期", english: "Overdue"))",
                            isActive: quickFocus == .overdue,
                            tint: overdueCount > 0 ? .red : .secondary
                        ) {
                            quickFocus = quickFocus == .overdue ? nil : .overdue
                        }

                        Spacer(minLength: 8)

                        Button {
                            showingFilters = true
                        } label: {
                            Image(systemName: advancedFilters.hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 32, height: 32)
                        .accessibilityLabel(Text(localizedAppText(for: settings.language, chinese: "筛选任务", english: "Filter tasks")))
                    }

                    Picker("", selection: $primaryFilter) {
                        ForEach(TaskPrimaryFilter.allCases, id: \.self) { filter in
                            Text(primaryFilterTitle(filter)).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(height: 30)

                    if advancedFilters.hasActiveFilters {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(activeFilterChipTitles, id: \.self) { title in
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                                        )
                                }
                            }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
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
                ForEach(taskSections) { section in
                    Section {
                        ForEach(section.tasks) { task in
                            taskRow(task)
                        }
                    } header: {
                        sectionHeader(section.title)
                    }
                }

                if primaryFilter != .done, !completedTasks.isEmpty {
                    Section {
                        DisclosureGroup(
                            isExpanded: $showingCompletedSection,
                            content: {
                                ForEach(completedTasks) { task in
                                    taskRow(task)
                                }
                            },
                            label: {
                                HStack {
                                    Text(localizedTasksText(chinese: "已完成", english: "Done"))
                                        .font(.headline)
                                    Spacer()
                                    Text("\(completedTasks.count)")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        )
                    } header: {
                        sectionHeader(localizedTasksText(chinese: "已完成", english: "Done"))
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
                    Image(systemName: "plus")
                }
            }
        }
        .task {
            await reload()
        }
        .sheet(item: $activeSheet) { destination in
            switch destination {
            case .create:
                TaskEditorSheet(task: nil, tags: viewModel.tags) { created in
                    viewModel.replace(created)
                }
            case let .detail(task):
                TaskEditorSheet(task: task, tags: viewModel.tags, startsInEditMode: true) { updated in
                    viewModel.replace(updated)
                }
            }
        }
        .sheet(item: $placementContext) { context in
            TimelinePlacementSheet(context: context) { _ in
                Task { @MainActor in
                    await reload()
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            TaskAdvancedFilterSheet(filters: $advancedFilters, availableTags: viewModel.tags, language: settings.language)
        }
        .refreshable {
            await reload()
        }
    }

    private var filteredTasks: [TaskDTO] {
        viewModel.tasks
            .filter { task in
                task.status != .archived
            }
            .filter(matchesPrimaryFilter)
            .filter(matchesAdvancedFilter)
            .filter(matchesQuickFocus)
            .sorted(by: taskComesFirst)
    }

    private var activeTasks: [TaskDTO] {
        filteredTasks.filter { $0.status != .done }
    }

    private var completedTasks: [TaskDTO] {
        filteredTasks.filter { $0.status == .done }
    }

    private func reload() async {
        await viewModel.load(using: environment.apiClient)
    }

    private var taskSections: [TaskHomeSection] {
        if primaryFilter == .done {
            return completedTasks.isEmpty
                ? []
                : [TaskHomeSection(id: "done", title: localizedTasksText(chinese: "已完成", english: "Done"), tasks: completedTasks)]
        }

        return [
            TaskHomeSection(id: "overdue", title: localizedTasksText(chinese: "已逾期", english: "Overdue"), tasks: activeTasks.filter(isOverdue)),
            TaskHomeSection(id: "today", title: localizedTasksText(chinese: "今天", english: "Today"), tasks: activeTasks.filter(isToday)),
            TaskHomeSection(id: "thisWeek", title: localizedTasksText(chinese: "本周", english: "This Week"), tasks: activeTasks.filter(isThisWeek)),
            TaskHomeSection(id: "later", title: localizedTasksText(chinese: "之后", english: "Later"), tasks: activeTasks.filter(isLater)),
            TaskHomeSection(id: "noDue", title: localizedTasksText(chinese: "无截止日期", english: "No Due"), tasks: activeTasks.filter(hasNoDueDate))
        ]
        .filter { !$0.tasks.isEmpty }
    }

    private var overdueCount: Int {
        viewModel.tasks.filter { $0.status != .done && isOverdue($0) }.count
    }

    private var todayCount: Int {
        viewModel.tasks.filter { $0.status != .done && isToday($0) }.count
    }

    private var plannedCount: Int {
        viewModel.tasks.filter { scheduledMinutes(for: $0) > 0 }.count
    }

    private var activeFilterChipTitles: [String] {
        var fragments: [String] = []
        if let quickFocus {
            switch quickFocus {
            case .today:
                fragments.append(localizedTasksText(chinese: "聚焦：今天", english: "Focus: Today"))
            case .planned:
                fragments.append(localizedTasksText(chinese: "聚焦：已规划", english: "Focus: Planned"))
            case .overdue:
                fragments.append(localizedTasksText(chinese: "聚焦：逾期", english: "Focus: Overdue"))
            }
        }
        let trimmedQuery = advancedFilters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            fragments.append(localizedTasksText(chinese: "搜索：\(trimmedQuery)", english: "Search: \(trimmedQuery)"))
        }
        if advancedFilters.dueFilter != .all {
            fragments.append(localizedTasksText(chinese: "截止：\(taskDueFilterLabel(advancedFilters.dueFilter))", english: "Due: \(taskDueFilterLabel(advancedFilters.dueFilter))"))
        }
        if !advancedFilters.selectedTagIDs.isEmpty {
            fragments.append(localizedTasksText(chinese: "标签 \(advancedFilters.selectedTagIDs.count) 个", english: "\(advancedFilters.selectedTagIDs.count) tag filters"))
        }
        return fragments
    }

    private func primaryFilterTitle(_ filter: TaskPrimaryFilter) -> String {
        switch filter {
        case .all:
            return localizedTasksText(chinese: "全部", english: "All")
        case .todo:
            return localizedTasksText(chinese: "待办", english: "Todo")
        case .doing:
            return localizedTasksText(chinese: "进行中", english: "Doing")
        case .done:
            return localizedTasksText(chinese: "已完成", english: "Done")
        }
    }

    private func taskDueFilterLabel(_ filter: TaskDueFilter) -> String {
        switch filter {
        case .all:
            return localizedTasksText(chinese: "全部", english: "All")
        case .today:
            return localizedTasksText(chinese: "今天", english: "Today")
        case .tomorrow:
            return localizedTasksText(chinese: "明天", english: "Tomorrow")
        case .thisWeek:
            return localizedTasksText(chinese: "本周", english: "This Week")
        case .thisMonth:
            return localizedTasksText(chinese: "本月", english: "This Month")
        }
    }

    @ViewBuilder
    private func taskRow(_ task: TaskDTO) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                Task { @MainActor in
                    await viewModel.cycle(task, using: environment.apiClient, notifications: environment.notificationScheduler)
                }
            } label: {
                Image(systemName: statusSymbol(for: task.status))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(statusColor(for: task.status))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            NavigationLink {
                TaskDetailView(task: task, availableTags: viewModel.tags) { updated in
                    viewModel.replace(updated)
                } onDelete: { deletedTaskID in
                    viewModel.tasks.removeAll { $0.id == deletedTaskID }
                }
            } label: {
                TaskListRowContent(
                    task: task,
                    language: settings.language,
                    scheduledMinutes: scheduledMinutes(for: task)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                placementContext = TimelinePlacementContext(
                    availableTasks: [task],
                    preselectedTaskID: task.id,
                    preselectedDate: Date.fromISO8601(task.dueAt) ?? .now,
                    preferredMode: .timed,
                    lockedSubTaskId: nil,
                    lockTaskSelection: true,
                    lockDeploymentTargetSelection: false
                )
            } label: {
                Label(localizedTasksText(chinese: "规划", english: "Schedule"), systemImage: "calendar.badge.plus")
            }
            .tint(.blue)

            Button {
                activeSheet = .detail(task)
            } label: {
                Label("common.edit", systemImage: "square.and.pencil")
            }
            .tint(SagePalette.brand)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { @MainActor in
                    await viewModel.delete(task, using: environment.apiClient, notifications: environment.notificationScheduler)
                }
            } label: {
                Label("common.delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
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
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.priority != rhs.priority {
            return lhs.priority.sortRank > rhs.priority.sortRank
        }

        return lhs.createdAt < rhs.createdAt
    }

    private func scheduledMinutes(for task: TaskDTO) -> Int {
        (task.timeBlocks ?? [])
            .filter { !$0.isAllDay }
            .compactMap { block in
                guard let start = Date.fromISO8601(block.startAt),
                      let end = Date.fromISO8601(block.endAt) else {
                    return nil
                }
                return max(0, Int(end.timeIntervalSince(start) / 60))
            }
            .reduce(0, +)
    }

    private func matchesPrimaryFilter(_ task: TaskDTO) -> Bool {
        switch primaryFilter {
        case .all:
            return true
        case .todo:
            return task.status == .todo || task.status == .inbox
        case .doing:
            return task.status == .doing
        case .done:
            return task.status == .done
        }
    }

    private func matchesAdvancedFilter(_ task: TaskDTO) -> Bool {
        let trimmedQuery = advancedFilters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            let haystack = [task.title, task.description ?? ""]
                .joined(separator: " ")
                .localizedLowercase
            if !haystack.contains(trimmedQuery.localizedLowercase) {
                return false
            }
        }

        if advancedFilters.dueFilter != .all, !matchesDueFilter(task, filter: advancedFilters.dueFilter) {
            return false
        }

        if !advancedFilters.selectedTagIDs.isEmpty {
            let taskTagIDs = Set(task.tags.map(\.id))
            if taskTagIDs.isDisjoint(with: advancedFilters.selectedTagIDs) {
                return false
            }
        }

        return true
    }

    private func matchesQuickFocus(_ task: TaskDTO) -> Bool {
        guard let quickFocus else { return true }

        switch quickFocus {
        case .today:
            return isToday(task)
        case .planned:
            return scheduledMinutes(for: task) > 0
        case .overdue:
            return isOverdue(task)
        }
    }

    private func matchesDueFilter(_ task: TaskDTO, filter: TaskDueFilter) -> Bool {
        guard let dueDate = taskSortDate(task) else { return false }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dueDay = calendar.startOfDay(for: dueDate)

        switch filter {
        case .all:
            return true
        case .today:
            return calendar.isDate(dueDay, inSameDayAs: today)
        case .tomorrow:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
            return calendar.isDate(dueDay, inSameDayAs: tomorrow)
        case .thisWeek:
            guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: today) else { return false }
            return dueDay >= weekInterval.start && dueDay < weekInterval.end
        case .thisMonth:
            guard let monthInterval = calendar.dateInterval(of: .month, for: today) else { return false }
            return dueDay >= monthInterval.start && dueDay < monthInterval.end
        }
    }

    private func isOverdue(_ task: TaskDTO) -> Bool {
        guard let dueDate = taskSortDate(task) else { return false }
        return Calendar.current.startOfDay(for: dueDate) < Calendar.current.startOfDay(for: Date())
    }

    private func isToday(_ task: TaskDTO) -> Bool {
        guard let dueDate = taskSortDate(task) else { return false }
        return Calendar.current.isDate(dueDate, inSameDayAs: Date())
    }

    private func isThisWeek(_ task: TaskDTO) -> Bool {
        guard let dueDate = taskSortDate(task) else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: today) else { return false }
        let nextWeekStart = weekInterval.end
        let dueDay = calendar.startOfDay(for: dueDate)
        return dueDay > today && dueDay < nextWeekStart
    }

    private func isLater(_ task: TaskDTO) -> Bool {
        guard let dueDate = taskSortDate(task) else { return false }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekInterval = calendar.dateInterval(of: .weekOfYear, for: today) else {
            return false
        }

        return calendar.startOfDay(for: dueDate) >= weekInterval.end
    }

    private func hasNoDueDate(_ task: TaskDTO) -> Bool {
        task.dueAt == nil
    }

    private func statusSymbol(for status: TaskStatus) -> String {
        switch status {
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

    private func statusColor(for status: TaskStatus) -> Color {
        switch status {
        case .done:
            return .green
        case .doing:
            return SagePalette.brand
        default:
            return .secondary
        }
    }

    @ViewBuilder
    private func summaryStatChip(title: String, isActive: Bool, tint: Color = SagePalette.brand, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isActive ? tint : .primary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(isActive ? tint.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isActive ? tint.opacity(0.25) : SagePalette.separator)
                )
        }
        .buttonStyle(.plain)
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
struct TaskListRowContent: View {
    let task: TaskDTO
    let language: AppLanguage
    let scheduledMinutes: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(task.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .strikethrough(task.status == .done)

                Spacer(minLength: 8)

                if let priorityLabel {
                    Text(priorityLabel)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(priorityTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(priorityTint.opacity(0.12))
                        )
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rowMetadata
                    CompactTaskRowTagStrip(tags: task.tags, limit: 2)
                }
                HStack(spacing: 10) {
                    rowMetadata
                    CompactTaskRowTagStrip(tags: task.tags, limit: 1)
                }
                rowMetadata
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var priorityLabel: String? {
        switch task.priority {
        case .low:
            return nil
        case .medium:
            return nil
        case .high:
            return localizedAppText(for: language, chinese: "高", english: "High")
        case .urgent:
            return localizedAppText(for: language, chinese: "急", english: "Urgent")
        }
    }

    private var priorityTint: Color {
        switch task.priority {
        case .urgent:
            return .red
        case .high:
            return SagePalette.brand
        case .medium:
            return .blue
        case .low:
            return .secondary
        }
    }

    @ViewBuilder
    private var rowMetadata: some View {
        HStack(spacing: 10) {
            if let dueAt = task.dueAt {
                compactMetaLabel(systemName: "calendar", title: formattedDue(dueAt), tint: dueTint)
            }

            if let estimateMinutes = task.estimateMinutes {
                compactMetaLabel(
                    systemName: "clock",
                    title: "\(scheduledMinutes)/\(estimateMinutes)m",
                    tint: scheduledMinutes >= estimateMinutes && estimateMinutes > 0 ? .green : .secondary
                )
            } else if scheduledMinutes > 0 {
                compactMetaLabel(systemName: "calendar.badge.clock", title: "\(scheduledMinutes)m", tint: .blue)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func compactMetaLabel(systemName: String, title: String, tint: Color) -> some View {
        Label(title, systemImage: systemName)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(tint)
    }

    private var dueTint: Color {
        guard let dueAt = task.dueAt, let date = Date.fromISO8601(dueAt) else { return .secondary }
        if Calendar.current.startOfDay(for: date) < Calendar.current.startOfDay(for: Date()) {
            return .red
        }
        if Calendar.current.isDateInToday(date) {
            return SagePalette.brand
        }
        return .secondary
    }

    private func formattedDue(_ string: String) -> String {
        guard let date = Date.fromISO8601(string) else { return string }
        if Calendar.current.isDateInToday(date) {
            return localizedAppText(for: language, chinese: "今天", english: "Today")
        }
        if Calendar.current.isDateInTomorrow(date) {
            return localizedAppText(for: language, chinese: "明天", english: "Tomorrow")
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private struct CompactTaskRowTagStrip: View {
    let tags: [TagDTO]
    let limit: Int

    var body: some View {
        let displayed = Array(tags.prefix(limit))
        let overflow = max(0, tags.count - displayed.count)

        HStack(spacing: 6) {
            ForEach(displayed) { tag in
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(hex: tag.color))
                        .frame(width: 6, height: 6)
                    Text(tag.name)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(uiColor: .secondarySystemGroupedBackground))
                )
            }

            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    )
            }
        }
        .lineLimit(1)
    }
}

@MainActor
private struct TaskAdvancedFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var filters: TaskAdvancedFilterState
    let availableTags: [TagDTO]
    let language: AppLanguage

    var body: some View {
        NavigationStack {
            Form {
                Section(localizedAppText(for: language, chinese: "搜索", english: "Search")) {
                    TextField(
                        localizedAppText(for: language, chinese: "按标题或描述搜索", english: "Search title or description"),
                        text: $filters.query
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section(localizedAppText(for: language, chinese: "截止时间", english: "Due")) {
                    Picker(
                        localizedAppText(for: language, chinese: "范围", english: "Scope"),
                        selection: $filters.dueFilter
                    ) {
                        ForEach(TaskDueFilter.allCases, id: \.self) { filter in
                            Text(dueFilterTitle(filter)).tag(filter)
                        }
                    }
                }

                if !availableTags.isEmpty {
                    Section(localizedAppText(for: language, chinese: "标签", english: "Tags")) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], alignment: .leading, spacing: 10) {
                            ForEach(availableTags) { tag in
                                Button {
                                    if filters.selectedTagIDs.contains(tag.id) {
                                        filters.selectedTagIDs.remove(tag.id)
                                    } else {
                                        filters.selectedTagIDs.insert(tag.id)
                                    }
                                } label: {
                                    TagChipView(tag: tag)
                                        .opacity(filters.selectedTagIDs.contains(tag.id) ? 1.0 : 0.42)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(localizedAppText(for: language, chinese: "任务筛选", english: "Task Filters"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(localizedAppText(for: language, chinese: "重置", english: "Reset")) {
                        filters = TaskAdvancedFilterState()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func dueFilterTitle(_ filter: TaskDueFilter) -> String {
        switch filter {
        case .all:
            return localizedAppText(for: language, chinese: "全部", english: "All")
        case .today:
            return localizedAppText(for: language, chinese: "今天", english: "Today")
        case .tomorrow:
            return localizedAppText(for: language, chinese: "明天", english: "Tomorrow")
        case .thisWeek:
            return localizedAppText(for: language, chinese: "本周", english: "This Week")
        case .thisMonth:
            return localizedAppText(for: language, chinese: "本月", english: "This Month")
        }
    }
}

@MainActor
struct TaskDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings

    let availableTags: [TagDTO]
    let onSave: (TaskDTO) -> Void
    let onDelete: (String) -> Void

    @State private var task: TaskDTO
    @State private var newSubtaskTitle = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var showingEditor = false
    @State private var placementContext: TimelinePlacementContext?
    @State private var editingBlock: TimeBlockDTO?
    @State private var confirmingDelete = false

    init(task: TaskDTO, availableTags: [TagDTO], onSave: @escaping (TaskDTO) -> Void, onDelete: @escaping (String) -> Void) {
        self.availableTags = availableTags
        self.onSave = onSave
        self.onDelete = onDelete
        _task = State(initialValue: task)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(task.title)
                        .font(.title3.weight(.semibold))
                        .strikethrough(task.status == .done)

                    if let description = task.description, !description.isEmpty {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    TaskMetadataListView(items: metadataItems)

                    Button {
                        placementContext = TimelinePlacementContext(
                            availableTasks: [task],
                            preselectedTaskID: task.id,
                            preselectedDate: Date.fromISO8601(task.dueAt) ?? .now,
                            preferredMode: .timed,
                            lockedSubTaskId: nil,
                            lockTaskSelection: true,
                            lockDeploymentTargetSelection: false
                        )
                    } label: {
                        Label(localizedAppText(for: settings.language, chinese: "在规划页安排", english: "Plan in Timeline"), systemImage: "calendar.badge.plus")
                            .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(SagePalette.brand)
                }
                .padding(.vertical, 4)
            }

            if !task.tags.isEmpty {
                Section(localizedAppText(for: settings.language, chinese: "标签", english: "Tags")) {
                    CompactTagStrip(tags: task.tags, limit: 99)
                        .padding(.vertical, 4)
                }
            }

            Section(localizedAppText(for: settings.language, chinese: "子任务", english: "Subtasks")) {
                if task.subtasks.isEmpty {
                    Text(localizedAppText(for: settings.language, chinese: "还没有子任务。", english: "No subtasks yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedSubtasks) { subtask in
                        InlineSubtaskRow(
                            subtask: subtask,
                            language: settings.language,
                            onCommitTitle: { title in
                                Task { @MainActor in
                                    await renameSubtask(subtask, title: title)
                                }
                            },
                            onToggle: {
                                Task { @MainActor in
                                    await toggleSubtask(subtask)
                                }
                            },
                            onDelete: {
                                Task { @MainActor in
                                    await deleteSubtask(subtask)
                                }
                            }
                        )
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(SagePalette.brand)

                    TextField(
                        localizedAppText(for: settings.language, chinese: "添加子任务", english: "Add subtask"),
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

            Section("timeline.title") {
                if sortedBlocks.isEmpty {
                    Text(localizedAppText(for: settings.language, chinese: "还没有日程或全天部署。", english: "No schedule blocks yet."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedBlocks, id: \.id) { block in
                        Button {
                            editingBlock = block
                        } label: {
                            TaskTimeBlockRow(title: blockSubtitle(block), subtitle: blockTitle(block))
                        }
                        .buttonStyle(.plain)
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
        .navigationTitle(task.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("common.edit") {
                    showingEditor = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
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
            TaskEditorSheet(task: task, tags: availableTags, startsInEditMode: true) { updated in
                task = updated
                onSave(updated)
            }
        }
        .sheet(item: $placementContext) { context in
            TimelinePlacementSheet(context: context) { _ in
                Task { @MainActor in
                    await reload()
                }
            }
        }
        .sheet(item: $editingBlock) { block in
            TimeBlockEditorSheet(task: task, existing: block) { _ in
                Task { @MainActor in
                    await reload()
                }
            } onDelete: {
                Task { @MainActor in
                    await reload()
                }
            }
        }
        .alert(localizedAppText(for: settings.language, chinese: "删除任务？", english: "Delete task?"), isPresented: $confirmingDelete) {
            Button("common.cancel", role: .cancel) {}
            Button("common.delete", role: .destructive) {
                Task { @MainActor in
                    await deleteTask()
                }
            }
        } message: {
            Text(localizedAppText(for: settings.language, chinese: "这个操作无法撤销。", english: "This action cannot be undone."))
        }
        .overlay {
            if isLoading {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var metadataItems: [TaskMetadataItem] {
        var items: [TaskMetadataItem] = [
            TaskMetadataItem(
                id: "status",
                label: localizedAppText(for: settings.language, chinese: "状态", english: "Status"),
                value: statusText(task.status),
                systemName: statusSymbol(for: task.status),
                tint: statusColor(for: task.status)
            ),
            TaskMetadataItem(
                id: "priority",
                label: localizedAppText(for: settings.language, chinese: "优先级", english: "Priority"),
                value: priorityText(task.priority),
                systemName: "flag",
                tint: priorityColor(task.priority)
            )
        ]

        if let dueAt = task.dueAt {
            items.append(
                TaskMetadataItem(
                    id: "due",
                    label: localizedAppText(for: settings.language, chinese: "截止时间", english: "Due"),
                    value: formattedDateTime(dueAt),
                    systemName: "calendar",
                    tint: .secondary
                )
            )
        }

        if let estimateMinutes = task.estimateMinutes {
            items.append(
                TaskMetadataItem(
                    id: "planned",
                    label: localizedAppText(for: settings.language, chinese: "规划进度", english: "Planned"),
                    value: "\(scheduledMinutes)/\(estimateMinutes)m",
                    systemName: "clock",
                    tint: scheduledMinutes >= estimateMinutes ? .green : .secondary
                )
            )
        } else if scheduledMinutes > 0 {
            items.append(
                TaskMetadataItem(
                    id: "scheduled",
                    label: localizedAppText(for: settings.language, chinese: "已规划", english: "Scheduled"),
                    value: "\(scheduledMinutes)m",
                    systemName: "calendar.badge.clock",
                    tint: .blue
                )
            )
        }

        return items
    }

    private var scheduledMinutes: Int {
        sortedBlocks
            .filter { !$0.isAllDay }
            .compactMap { block in
                guard let start = Date.fromISO8601(block.startAt),
                      let end = Date.fromISO8601(block.endAt) else {
                    return nil
                }
                return max(0, Int(end.timeIntervalSince(start) / 60))
            }
            .reduce(0, +)
    }

    private var sortedSubtasks: [SubTaskDTO] {
        task.subtasks.sorted { lhs, rhs in
            if lhs.sortOrder != rhs.sortOrder {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var sortedBlocks: [TimeBlockDTO] {
        (task.timeBlocks ?? []).sorted { lhs, rhs in
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
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let refreshed: TaskDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(task.id)")
            task = refreshed
            onSave(refreshed)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task { @MainActor in
            do {
                let _: SubTaskDTO = try await environment.apiClient.send(
                    path: "/api/mobile/v1/tasks/\(task.id)/subtasks",
                    method: "POST",
                    body: NewSubtaskRequest(title: trimmed)
                )
                newSubtaskTitle = ""
                await reload()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renameSubtask(_ subtask: SubTaskDTO, title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != subtask.title else { return }

        do {
            let _: SubTaskDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/subtasks/\(subtask.id)",
                method: "PATCH",
                body: SubtaskPatchRequest(title: trimmed, done: subtask.done, sortOrder: subtask.sortOrder)
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleSubtask(_ subtask: SubTaskDTO) async {
        do {
            let _: SubTaskDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/subtasks/\(subtask.id)",
                method: "PATCH",
                body: SubtaskPatchRequest(title: subtask.title, done: !subtask.done, sortOrder: subtask.sortOrder)
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSubtask(_ subtask: SubTaskDTO) async {
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/subtasks/\(subtask.id)",
                method: "DELETE",
                body: EmptyBody()
            )
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTask() async {
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/tasks/\(task.id)",
                method: "DELETE",
                body: EmptyBody()
            )
            await environment.notificationScheduler.cancelReminder(for: task.id)
            onDelete(task.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func blockTitle(_ block: TimeBlockDTO) -> String {
        deploymentTargetTitle(for: task, subTaskId: block.subTaskId, language: settings.language)
    }

    private func blockSubtitle(_ block: TimeBlockDTO) -> String {
        if block.isAllDay {
            let mode = block.originTimeBlockId == nil
                ? localizedAppText(for: settings.language, chinese: "手动部署", english: "Manual assignment")
                : localizedAppText(for: settings.language, chinese: "自动同步部署", english: "Auto assignment")
            return "\(formattedDateTime(block.startAt)) · \(mode)"
        }

        return "\(formattedDateTime(block.startAt)) - \(Date.fromISO8601(block.endAt)?.formatted(date: .omitted, time: .shortened) ?? block.endAt)"
    }

    private func formattedDateTime(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .shortened) ?? string
    }

    private func statusSymbol(for status: TaskStatus) -> String {
        switch status {
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

    private func statusText(_ status: TaskStatus) -> String {
        switch status {
        case .done:
            return localizedAppText(for: settings.language, chinese: "已完成", english: "Done")
        case .doing:
            return localizedAppText(for: settings.language, chinese: "进行中", english: "Doing")
        case .inbox:
            return localizedAppText(for: settings.language, chinese: "收件箱", english: "Inbox")
        case .archived:
            return localizedAppText(for: settings.language, chinese: "已归档", english: "Archived")
        case .todo:
            return localizedAppText(for: settings.language, chinese: "待办", english: "Todo")
        }
    }

    private func statusColor(for status: TaskStatus) -> Color {
        switch status {
        case .done:
            return .green
        case .doing:
            return SagePalette.brand
        default:
            return .secondary
        }
    }

    private func priorityText(_ priority: TaskPriority) -> String {
        switch priority {
        case .low:
            return localizedAppText(for: settings.language, chinese: "低", english: "Low")
        case .medium:
            return localizedAppText(for: settings.language, chinese: "中", english: "Medium")
        case .high:
            return localizedAppText(for: settings.language, chinese: "高", english: "High")
        case .urgent:
            return localizedAppText(for: settings.language, chinese: "紧急", english: "Urgent")
        }
    }

    private func priorityColor(_ priority: TaskPriority) -> Color {
        switch priority {
        case .urgent:
            return .red
        case .high:
            return SagePalette.brand
        case .medium:
            return .blue
        case .low:
            return .secondary
        }
    }
}

private struct TaskMetadataItem: Identifiable {
    let id: String
    let label: String
    let value: String
    let systemName: String
    let tint: Color
}

private struct TaskMetadataListView: View {
    let items: [TaskMetadataItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .center, spacing: 12) {
                    Label(item.label, systemImage: item.systemName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 12)

                    Text(item.value)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                if index < items.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(SagePalette.separator)
        )
    }
}

private struct TaskTimeBlockRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.body.weight(.semibold))
                .foregroundStyle(SagePalette.brand)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
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

    init(task: TaskDTO?, tags: [TagDTO], startsInEditMode: Bool = false, onSave: @escaping (TaskDTO) -> Void) {
        self.task = task
        self.tags = tags
        self.onSave = onSave
        _mode = State(initialValue: task == nil || startsInEditMode ? .edit : .view)
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
