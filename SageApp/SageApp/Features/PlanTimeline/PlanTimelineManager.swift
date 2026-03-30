import Foundation
import SwiftUI

@MainActor
final class PlanTimelineManager: ObservableObject {
    @Published var blocks: [TimelineBlockDTO] = []
    @Published var tasks: [TaskDTO] = []
    @Published var sections: [PlanDaySection] = []
    @Published var unscheduledTasks: [TaskDTO] = []
    @Published var calendarDensity: [PlanCalendarDensity] = []
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: .now)
    @Published var visibleMonth: Date = Calendar.current.startOfDay(for: .now)
    @Published var visibleYear: Int = Calendar.current.component(.year, from: .now)
    @Published var isLoading = false
    @Published var errorMessage: String?

    let pageState = PlanPageScrollState()
    let listScrollState = PlanListScrollState()
    var onScheduledItemTap: ((PlanTimelineItem) -> Void)?
    var onPlacementRequested: ((TimelinePlacementContext) -> Void)?

    var language: AppLanguage = .english {
        didSet {
            recomputeSections()
        }
    }

    private let repository = PlanTimelineRepository()
    private weak var environment: AppEnvironment?
    private var hasPerformedInitialLoad = false

    init() {
        listScrollState.onVisibleDateChanged = { [weak self] date in
            guard let self else { return }
            self.selectedDate = Calendar.current.startOfDay(for: date)
            self.visibleMonth = self.startOfMonth(for: date)
            self.visibleYear = Calendar.current.component(.year, from: date)
        }
    }

    func initialLoad(using environment: AppEnvironment) async {
        self.environment = environment
        if hasPerformedInitialLoad {
            await reloadVisibleRange(using: environment)
        } else {
            hasPerformedInitialLoad = true
            await reloadVisibleRange(using: environment)
        }
    }

    func reloadVisibleRange(using environment: AppEnvironment? = nil) async {
        guard let environment = environment ?? self.environment else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let range = PlanVisibleRange.year(visibleYear)

        do {
            async let blocksRequest = repository.loadTimeline(start: range.start, end: range.end, using: environment)
            async let tasksRequest = repository.loadTasks(using: environment)
            blocks = try await blocksRequest
            tasks = try await tasksRequest
            recomputeSections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(date: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        visibleMonth = startOfMonth(for: selectedDate)
        let year = Calendar.current.component(.year, from: selectedDate)
        if year != visibleYear {
            visibleYear = year
            Task { @MainActor [weak self] in
                await self?.reloadVisibleRange()
                self?.listScrollState.scroll(to: self?.selectedDate ?? date, animated: false)
            }
        } else {
            listScrollState.scroll(to: selectedDate, animated: true)
        }
    }

    func scrollToToday() {
        select(date: .now)
    }

    func scrollTo(date: Date) {
        select(date: date)
    }

    func jumpToMonth(_ month: Date) {
        let targetMonth = startOfMonth(for: month)
        let selectedDay = Calendar.current.component(.day, from: selectedDate)
        let daysInMonth = Calendar.current.range(of: .day, in: .month, for: targetMonth)?.count ?? 28
        let targetDay = min(selectedDay, daysInMonth)
        let components = Calendar.current.dateComponents([.year, .month], from: targetMonth)
        let targetDate = Calendar.current.date(
            from: DateComponents(year: components.year, month: components.month, day: targetDay)
        ) ?? targetMonth

        visibleMonth = targetMonth
        let year = Calendar.current.component(.year, from: targetMonth)
        selectedDate = Calendar.current.startOfDay(for: targetDate)

        if year != visibleYear {
            visibleYear = year
            Task { @MainActor [weak self] in
                await self?.reloadVisibleRange()
                self?.listScrollState.scroll(to: self?.selectedDate ?? targetDate, animated: false)
            }
        } else {
            listScrollState.scroll(to: selectedDate, animated: false)
        }
    }

    func jumpToYear(_ year: Int) {
        visibleYear = year
        visibleMonth = Calendar.current.date(from: DateComponents(year: year, month: visibleMonthMonth)) ?? visibleMonth
        selectedDate = Calendar.current.date(from: DateComponents(year: year, month: visibleMonthMonth, day: 1)) ?? selectedDate
        Task { @MainActor [weak self] in
            await self?.reloadVisibleRange()
        }
    }

    func refreshTask(id: String, using environment: AppEnvironment? = nil) async {
        guard let environment = environment ?? self.environment else { return }
        do {
            let refreshed = try await repository.loadTask(id: id, using: environment)
            if let index = tasks.firstIndex(where: { $0.id == id }) {
                tasks[index] = refreshed
            } else {
                tasks.append(refreshed)
            }

            blocks = blocks.map { block in
                guard block.taskId == refreshed.id else { return block }
                return TimelineBlockDTO(
                    id: block.id,
                    taskId: block.taskId,
                    startAt: block.startAt,
                    endAt: block.endAt,
                    subTaskId: block.subTaskId,
                    isAllDay: block.isAllDay,
                    originTimeBlockId: block.originTimeBlockId,
                    createdAt: block.createdAt,
                    updatedAt: block.updatedAt,
                    task: refreshed
                )
            }
            recomputeSections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createBlock(taskId: String, request: TimeBlockWriteRequest, using environment: AppEnvironment? = nil) async {
        guard let environment = environment ?? self.environment else { return }
        do {
            let block = try await repository.createTimeBlock(taskId: taskId, request: request, using: environment)
            let task = try await repository.loadTask(id: taskId, using: environment)
            tasks.replaceOrAppend(task)
            blocks.replaceOrAppend(
                TimelineBlockDTO(
                    id: block.id,
                    taskId: block.taskId,
                    startAt: block.startAt,
                    endAt: block.endAt,
                    subTaskId: block.subTaskId,
                    isAllDay: block.isAllDay,
                    originTimeBlockId: block.originTimeBlockId,
                    createdAt: block.createdAt,
                    updatedAt: block.updatedAt,
                    task: task
                )
            )
            recomputeSections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func editBlock(id: String, request: TimeBlockWriteRequest, using environment: AppEnvironment? = nil) async {
        guard let environment = environment ?? self.environment else { return }
        do {
            let block = try await repository.updateTimeBlock(id: id, request: request, using: environment)
            guard let existing = blocks.first(where: { $0.id == id }) else {
                await reloadVisibleRange(using: environment)
                return
            }
            blocks.replaceOrAppend(
                TimelineBlockDTO(
                    id: block.id,
                    taskId: block.taskId,
                    startAt: block.startAt,
                    endAt: block.endAt,
                    subTaskId: block.subTaskId,
                    isAllDay: block.isAllDay,
                    originTimeBlockId: block.originTimeBlockId,
                    createdAt: block.createdAt,
                    updatedAt: block.updatedAt,
                    task: existing.task
                )
            )
            recomputeSections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBlock(id: String, using environment: AppEnvironment? = nil) async {
        guard let environment = environment ?? self.environment else { return }
        do {
            try await repository.deleteTimeBlock(id: id, using: environment)
            blocks.removeAll { $0.id == id }
            recomputeSections()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func ingestCreatedBlock(_ block: TimeBlockDTO) {
        if let task = tasks.first(where: { $0.id == block.taskId }) {
            blocks.replaceOrAppend(
                TimelineBlockDTO(
                    id: block.id,
                    taskId: block.taskId,
                    startAt: block.startAt,
                    endAt: block.endAt,
                    subTaskId: block.subTaskId,
                    isAllDay: block.isAllDay,
                    originTimeBlockId: block.originTimeBlockId,
                    createdAt: block.createdAt,
                    updatedAt: block.updatedAt,
                    task: task
                )
            )
            recomputeSections()
        }
        Task { @MainActor [weak self] in
            await self?.refreshTask(id: block.taskId)
        }
    }

    func ingestUpdatedBlock(_ block: TimeBlockDTO) {
        guard let existing = blocks.first(where: { $0.id == block.id }) else {
            ingestCreatedBlock(block)
            return
        }

        blocks.replaceOrAppend(
            TimelineBlockDTO(
                id: block.id,
                taskId: block.taskId,
                startAt: block.startAt,
                endAt: block.endAt,
                subTaskId: block.subTaskId,
                isAllDay: block.isAllDay,
                originTimeBlockId: block.originTimeBlockId,
                createdAt: block.createdAt,
                updatedAt: block.updatedAt,
                task: existing.task
            )
        )
        recomputeSections()
        Task { @MainActor [weak self] in
            await self?.refreshTask(id: block.taskId)
        }
    }

    func removeBlockLocally(id: String) {
        let removedTaskID = blocks.first(where: { $0.id == id })?.taskId
        blocks.removeAll { $0.id == id }
        recomputeSections()
        if let removedTaskID {
            Task { @MainActor [weak self] in
                await self?.refreshTask(id: removedTaskID)
            }
        }
    }

    func handleTap(on item: PlanTimelineItem) {
        if item.timeBlockId != nil {
            onScheduledItemTap?(item)
        } else {
            presentPlacement(for: item.date)
        }
    }

    func presentPlacement(for date: Date) {
        guard !tasks.isEmpty else { return }
        onPlacementRequested?(
            TimelinePlacementContext(
                availableTasks: tasks.filter { $0.status != .archived },
                preselectedTaskID: nil,
                preselectedDate: date,
                preferredMode: .timed,
                lockedSubTaskId: nil,
                lockTaskSelection: false,
                lockDeploymentTargetSelection: false
            )
        )
    }

    func presentPlacement(for task: TaskDTO) {
        onPlacementRequested?(
            TimelinePlacementContext(
                availableTasks: [task],
                preselectedTaskID: task.id,
                preselectedDate: Date.fromISO8601(task.dueAt) ?? selectedDate,
                preferredMode: .timed,
                lockedSubTaskId: nil,
                lockTaskSelection: true,
                lockDeploymentTargetSelection: false
            )
        )
    }

    func recomputeSections() {
        let range = PlanVisibleRange.year(visibleYear)
        let items = makePlanTimelineItems(from: blocks, language: language)
        sections = makePlanDaySections(items: items, range: range)
        unscheduledTasks = makeUnscheduledTasks(from: tasks)
        recomputeCalendarDensity()
        listScrollState.configure(with: sections.map(\.date), selectedDate: selectedDate)
    }

    func recomputeCalendarDensity() {
        calendarDensity = makePlanCalendarDensity(sections: sections, tasks: tasks)
    }

    func density(for date: Date) -> PlanCalendarDensity {
        calendarDensity.first(where: { Calendar.current.isDate($0.date, inSameDayAs: date) })
        ?? PlanCalendarDensity(date: date, scheduledCount: 0, dueCount: 0, hasUrgent: false)
    }

    var currentRange: PlanVisibleRange {
        PlanVisibleRange.year(visibleYear)
    }

    private var visibleMonthMonth: Int {
        Calendar.current.component(.month, from: visibleMonth)
    }

    private func startOfMonth(for date: Date) -> Date {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: components) ?? date
    }
}

private extension Array where Element == TaskDTO {
    mutating func replaceOrAppend(_ task: TaskDTO) {
        if let index = firstIndex(where: { $0.id == task.id }) {
            self[index] = task
        } else {
            append(task)
        }
    }
}

private extension Array where Element == TimelineBlockDTO {
    mutating func replaceOrAppend(_ block: TimelineBlockDTO) {
        if let index = firstIndex(where: { $0.id == block.id }) {
            self[index] = block
        } else {
            append(block)
        }
    }
}
