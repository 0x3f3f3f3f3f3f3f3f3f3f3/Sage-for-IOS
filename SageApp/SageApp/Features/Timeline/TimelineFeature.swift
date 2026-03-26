import SwiftUI
import Observation

enum TimelineMode: String, CaseIterable, Hashable, Identifiable {
    case week
    case month

    var id: String { rawValue }
}

@MainActor
@Observable
final class TimelineViewModel {
    var blocks: [TimelineBlockDTO] = []
    var tasks: [TaskDTO] = []
    var mode: TimelineMode = .week
    var anchorDate = Date()
    var isLoading = false
    var errorMessage: String?

    func load(using api: APIClient) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let range = dateRange
            let formatter = DateFormatter.makeOffsetISO8601()
            let timelinePath = makeAPIPath(
                "/api/mobile/v1/timeline",
                queryItems: [
                    URLQueryItem(name: "start", value: formatter.string(from: range.start)),
                    URLQueryItem(name: "end", value: formatter.string(from: range.end))
                ]
            )
            async let blocksRequest: [TimelineBlockDTO] = api.send(path: timelinePath)
            async let tasksRequest: [TaskDTO] = api.send(path: "/api/mobile/v1/tasks")
            blocks = try await blocksRequest
            tasks = try await tasksRequest
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchorDate)
        let displayEnd: Date

        switch mode {
        case .week:
            displayEnd = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        case .month:
            displayEnd = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        }

        let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: displayEnd)) ?? displayEnd
        return (start, exclusiveEnd)
    }

    var displayEndDate: Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchorDate)

        switch mode {
        case .week:
            return calendar.date(byAdding: .day, value: 7, to: start) ?? start
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: start) ?? start
        }
    }
}

@MainActor
struct TimelineScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = TimelineViewModel()
    @State private var selectedBlock: TimelineBlockDTO?
    @State private var placementContext: TimelinePlacementContext?

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Text(rangeTitle)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    GlassToolbarButton(systemName: "chevron.left") {
                        shift(-1)
                    }

                    GlassSegmentedFilterRow(items: TimelineMode.allCases, title: timelineModeTitle, selection: $viewModel.mode)

                    GlassToolbarButton(systemName: "chevron.right") {
                        shift(1)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            List {
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
                } else {
                    ForEach(daySections) { section in
                        Section {
                            TimelineDayHeader(
                                day: section.day,
                                language: environment.settings.language,
                                onAddAssignment: {
                                    placementContext = TimelinePlacementContext(
                                        availableTasks: viewModel.tasks,
                                        preselectedTaskID: nil,
                                        preselectedDate: section.day,
                                        preferredMode: .assignment,
                                        lockedSubTaskId: nil,
                                        lockTaskSelection: false,
                                        lockDeploymentTargetSelection: false
                                    )
                                },
                                onAddTimedBlock: {
                                    placementContext = TimelinePlacementContext(
                                        availableTasks: viewModel.tasks,
                                        preselectedTaskID: nil,
                                        preselectedDate: section.day,
                                        preferredMode: .timed,
                                        lockedSubTaskId: nil,
                                        lockTaskSelection: false,
                                        lockDeploymentTargetSelection: false
                                    )
                                }
                            )
                            .listRowBackground(Color.clear)

                            TimelineAssignmentStrip(
                                assignments: section.assignments,
                                language: environment.settings.language,
                                onSelect: { block in
                                    selectedBlock = block
                                },
                                onAddAssignment: {
                                    placementContext = TimelinePlacementContext(
                                        availableTasks: viewModel.tasks,
                                        preselectedTaskID: nil,
                                        preselectedDate: section.day,
                                        preferredMode: .assignment,
                                        lockedSubTaskId: nil,
                                        lockTaskSelection: false,
                                        lockDeploymentTargetSelection: false
                                    )
                                }
                            )
                            .listRowBackground(Color.clear)

                            if section.timedBlocks.isEmpty {
                                Text(localizedTimelineText(chinese: "这一天还没有安排时间块。", english: "No timed blocks scheduled for this day."))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                                    .listRowBackground(Color.clear)
                            } else {
                                ForEach(section.timedBlocks) { block in
                                    Button {
                                        selectedBlock = block
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(block.task.title)
                                                    .font(.body.weight(.semibold))
                                                Spacer()
                                                Text(blockTimeRange(block))
                                                    .font(.footnote.weight(.medium))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text(deploymentTargetTitle(for: block.task, subTaskId: block.subTaskId, language: environment.settings.language))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                }
            }
            .sageListChrome()
        }
        .navigationTitle(localizedAppText(for: settings.language, chinese: "日程", english: "Timeline"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    placementContext = TimelinePlacementContext(
                        availableTasks: viewModel.tasks,
                        preselectedTaskID: nil,
                        preselectedDate: visibleDays.first ?? Date(),
                        preferredMode: .timed,
                        lockedSubTaskId: nil,
                        lockTaskSelection: false,
                        lockDeploymentTargetSelection: false
                    )
                } label: {
                    Label("timeline.addBlock", systemImage: "plus")
                }
                .disabled(viewModel.tasks.isEmpty)
            }
        }
        .task(id: reloadKey) {
            await reload()
        }
        .sheet(item: $selectedBlock) { block in
            TimelineBlockInspectorSheet(block: block) {
                Task { @MainActor in
                    await reload()
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
        .refreshable {
            await reload()
        }
    }

    private var daySections: [TimelineDaySection] {
        visibleDays.map { day in
            let assignments = viewModel.blocks
                .filter { block in
                    block.isAllDay && blockMatchesDay(block, day: day)
                }
                .sorted(by: assignmentComesFirst)

            let timedBlocks = viewModel.blocks
                .filter { block in
                    !block.isAllDay && blockMatchesDay(block, day: day)
                }
                .sorted(by: timedBlockComesFirst)

            return TimelineDaySection(day: day, assignments: assignments, timedBlocks: timedBlocks)
        }
    }

    private var visibleDays: [Date] {
        let calendar = Calendar.current
        let range = viewModel.dateRange
        var current = calendar.startOfDay(for: range.start)
        let end = range.end
        var days: [Date] = []

        while current < end {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? end
        }

        return days
    }

    private var rangeTitle: String {
        let range = viewModel.dateRange
        let endDisplay = viewModel.displayEndDate
        return "\(range.start.formatted(date: .abbreviated, time: .omitted)) - \(endDisplay.formatted(date: .abbreviated, time: .omitted))"
    }

    private var reloadKey: String {
        "\(viewModel.mode.rawValue)-\(viewModel.anchorDate.timeIntervalSinceReferenceDate)"
    }

    private func reload() async {
        await viewModel.load(using: environment.apiClient)
    }

    private func shift(_ offset: Int) {
        switch viewModel.mode {
        case .week:
            viewModel.anchorDate = Calendar.current.date(byAdding: .day, value: offset * 7, to: viewModel.anchorDate) ?? viewModel.anchorDate
        case .month:
            viewModel.anchorDate = Calendar.current.date(byAdding: .month, value: offset, to: viewModel.anchorDate) ?? viewModel.anchorDate
        }
    }

    private func timelineModeTitle(_ mode: TimelineMode) -> LocalizedStringKey {
        switch mode {
        case .week: return "tasks.view.week"
        case .month: return "tasks.view.month"
        }
    }

    private func blockMatchesDay(_ block: TimelineBlockDTO, day: Date) -> Bool {
        guard let start = Date.fromISO8601(block.startAt) else { return false }
        return Calendar.current.isDate(start, inSameDayAs: day)
    }

    private func blockTimeRange(_ block: TimelineBlockDTO) -> String {
        let start = Date.fromISO8601(block.startAt)?.formatted(date: .omitted, time: .shortened) ?? block.startAt
        let end = Date.fromISO8601(block.endAt)?.formatted(date: .omitted, time: .shortened) ?? block.endAt
        return "\(start) - \(end)"
    }

    private func assignmentComesFirst(_ lhs: TimelineBlockDTO, _ rhs: TimelineBlockDTO) -> Bool {
        if lhs.originTimeBlockId != rhs.originTimeBlockId {
            return lhs.originTimeBlockId == nil
        }

        let lhsTitle = timelineAssignmentTitle(for: lhs)
        let rhsTitle = timelineAssignmentTitle(for: rhs)
        return lhsTitle < rhsTitle
    }

    private func timedBlockComesFirst(_ lhs: TimelineBlockDTO, _ rhs: TimelineBlockDTO) -> Bool {
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

    private func localizedTimelineText(chinese: String, english: String) -> String {
        localizedAppText(for: environment.settings.language, chinese: chinese, english: english)
    }

    private func timelineAssignmentTitle(for block: TimelineBlockDTO) -> String {
        if let subTaskId = block.subTaskId,
           let subtask = block.task.subtasks.first(where: { $0.id == subTaskId }) {
            return subtask.title
        }

        return block.task.title
    }
}

private struct TimelineDaySection: Identifiable {
    let day: Date
    let assignments: [TimelineBlockDTO]
    let timedBlocks: [TimelineBlockDTO]

    var id: String {
        String(day.timeIntervalSinceReferenceDate)
    }
}

@MainActor
private struct TimelineDayHeader: View {
    let day: Date
    let language: AppLanguage
    let onAddAssignment: () -> Void
    let onAddTimedBlock: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(date: .complete, time: .omitted))
                    .font(.headline.weight(.semibold))
                Text(localizedAppText(for: language, chinese: "待部署区和时间块", english: "Assignments and timed blocks"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button(action: onAddAssignment) {
                    Label(localizedAppText(for: language, chinese: "加入待部署区", english: "Add assignment"), systemImage: "square.stack.badge.plus")
                }
                Button(action: onAddTimedBlock) {
                    Label(localizedAppText(for: language, chinese: "安排时间", english: "Schedule time"), systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct TimelineAssignmentStrip: View {
    let assignments: [TimelineBlockDTO]
    let language: AppLanguage
    let onSelect: (TimelineBlockDTO) -> Void
    let onAddAssignment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizedAppText(for: language, chinese: "待部署区", english: "Deployment row"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if assignments.isEmpty {
                        Button(action: onAddAssignment) {
                            Label(localizedAppText(for: language, chinese: "加入待部署区", english: "Add assignment"), systemImage: "plus")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(assignments) { assignment in
                            Button {
                                onSelect(assignment)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(assignment.originTimeBlockId == nil ? Color.orange : Color.blue)
                                        .frame(width: 8, height: 8)
                                    Text(timelineAssignmentTitle(for: assignment))
                                        .lineLimit(1)
                                        .font(.footnote.weight(.semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func timelineAssignmentTitle(for assignment: TimelineBlockDTO) -> String {
        if let subTaskId = assignment.subTaskId,
           let subtask = assignment.task.subtasks.first(where: { $0.id == subTaskId }) {
            return subtask.title
        }

        return assignment.task.title
    }
}

@MainActor
private struct TimelineBlockInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let block: TimelineBlockDTO
    let onChanged: () -> Void

    @State private var currentTask: TaskDTO
    @State private var currentBlock: TimeBlockDTO
    @State private var showingEditor = false
    @State private var placementContext: TimelinePlacementContext?
    @State private var errorMessage: String?

    init(block: TimelineBlockDTO, onChanged: @escaping () -> Void) {
        self.block = block
        self.onChanged = onChanged
        _currentTask = State(initialValue: block.task)
        _currentBlock = State(
            initialValue: TimeBlockDTO(
                id: block.id,
                taskId: block.taskId,
                startAt: block.startAt,
                endAt: block.endAt,
                subTaskId: block.subTaskId,
                isAllDay: block.isAllDay,
                originTimeBlockId: block.originTimeBlockId,
                createdAt: block.createdAt,
                updatedAt: block.updatedAt
            )
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentTask.title)
                            .font(.title3.weight(.bold))
                        Text(primaryDescription)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section(localizedAppText(for: environment.settings.language, chinese: "部署对象", english: "Deployment target")) {
                    ForEach(deploymentOptions(for: currentTask, language: environment.settings.language)) { option in
                        Button {
                            Task { @MainActor in
                                await updateDeploymentTarget(option)
                            }
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if currentBlock.subTaskId == option.subTaskId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !currentTask.subtasks.isEmpty {
                    Section(localizedAppText(for: environment.settings.language, chinese: "子任务", english: "Subtasks")) {
                        ForEach(currentTask.subtasks.sorted(by: subtaskComesFirst)) { subtask in
                            HStack(spacing: 10) {
                                Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(subtask.done ? .green : .secondary)
                                Text(subtask.title)
                                    .strikethrough(subtask.done)
                            }
                        }
                    }
                }

                if currentBlock.isAllDay {
                    Section {
                        Button {
                            placementContext = TimelinePlacementContext(
                                availableTasks: [currentTask],
                                preselectedTaskID: currentTask.id,
                                preselectedDate: Date.fromISO8601(currentBlock.startAt) ?? .now,
                                preferredMode: .timed,
                                lockedSubTaskId: currentBlock.subTaskId,
                                lockTaskSelection: true,
                                lockDeploymentTargetSelection: true
                            )
                        } label: {
                            Label(localizedAppText(for: environment.settings.language, chinese: "按当前部署对象安排时间", english: "Schedule with this deployment target"), systemImage: "calendar.badge.plus")
                        }

                        if currentBlock.originTimeBlockId != nil {
                            Text(localizedAppText(for: environment.settings.language, chinese: "这是由时间块自动补出的部署项，删除对应时间块后会一起消失。", english: "This assignment was auto-created from a timed block and will disappear with that timed block."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Button(role: .destructive) {
                                Task { @MainActor in
                                    await deleteAssignment()
                                }
                            } label: {
                                Label("common.delete", systemImage: "trash")
                            }
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
            .navigationTitle(currentBlock.isAllDay ? LocalizedStringKey("timeline.allDay") : LocalizedStringKey("timeline.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                if !currentBlock.isAllDay {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.edit") {
                            showingEditor = true
                        }
                    }
                }
            }
            .task {
                await refreshTask()
            }
            .sheet(isPresented: $showingEditor) {
                TimeBlockEditorSheet(task: currentTask, existing: currentBlock) { saved in
                    currentBlock = saved
                    onChanged()
                    Task { @MainActor in
                        await refreshTask()
                    }
                } onDelete: {
                    onChanged()
                    dismiss()
                }
            }
            .sheet(item: $placementContext) { context in
                TimelinePlacementSheet(context: context) { _ in
                    onChanged()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var primaryDescription: String {
        if currentBlock.isAllDay {
            let date = Date.fromISO8601(currentBlock.startAt)?.formatted(date: .complete, time: .omitted) ?? currentBlock.startAt
            let originLabel = currentBlock.originTimeBlockId == nil
                ? localizedAppText(for: environment.settings.language, chinese: "手动部署", english: "Manual assignment")
                : localizedAppText(for: environment.settings.language, chinese: "自动同步部署", english: "Auto assignment")
            return "\(date) · \(originLabel)"
        }

        let start = Date.fromISO8601(currentBlock.startAt)?.formatted(date: .abbreviated, time: .shortened) ?? currentBlock.startAt
        let end = Date.fromISO8601(currentBlock.endAt)?.formatted(date: .omitted, time: .shortened) ?? currentBlock.endAt
        return "\(start) - \(end)"
    }

    private func refreshTask() async {
        do {
            let refreshed: TaskDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(currentTask.id)")
            currentTask = refreshed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateDeploymentTarget(_ option: DeploymentTargetOption) async {
        guard currentBlock.subTaskId != option.subTaskId else { return }

        do {
            let request = TimeBlockWriteRequest(
                startAt: currentBlock.startAt,
                endAt: currentBlock.endAt,
                subTaskId: option.subTaskId,
                isAllDay: currentBlock.isAllDay
            )
            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(currentBlock.id)",
                method: "PATCH",
                body: request
            )
            currentBlock = saved
            errorMessage = nil
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAssignment() async {
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(currentBlock.id)",
                method: "DELETE",
                body: EmptyBody()
            )
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subtaskComesFirst(_ lhs: SubTaskDTO, _ rhs: SubTaskDTO) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.createdAt < rhs.createdAt
    }
}
