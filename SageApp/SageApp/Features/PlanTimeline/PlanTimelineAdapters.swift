import Foundation

func makePlanTimelineItems(
    from blocks: [TimelineBlockDTO],
    language: AppLanguage,
    now: Date = .now,
    calendar: Calendar = .current
) -> [PlanTimelineItem] {
    blocks.compactMap { block in
        guard let start = Date.fromISO8601(block.startAt),
              let end = Date.fromISO8601(block.endAt) else {
            return nil
        }

        let matchedSubtask = block.subTaskId.flatMap { subTaskID in
            block.task.subtasks.first(where: { $0.id == subTaskID })
        }

        let title = matchedSubtask?.title ?? block.task.title
        let subtitle: String
        if matchedSubtask != nil {
            subtitle = block.task.title
        } else if block.isAllDay {
            subtitle = localizedAppText(for: language, chinese: "全天", english: "All day")
        } else {
            let startText = start.formatted(date: .omitted, time: .shortened)
            let endText = end.formatted(date: .omitted, time: .shortened)
            subtitle = "\(startText) – \(endText)"
        }

        let dueAt = Date.fromISO8601(block.task.dueAt)
        let isCompleted = block.task.status == .done || block.task.completedAt != nil
        let isOverdue = !isCompleted && dueAt.map { $0 < now } == true

        return PlanTimelineItem(
            id: block.id,
            taskId: block.taskId,
            timeBlockId: block.id,
            subTaskId: block.subTaskId,
            date: calendar.startOfDay(for: start),
            startAt: start,
            endAt: end,
            isAllDay: block.isAllDay,
            title: title,
            subtitle: subtitle,
            status: block.task.status,
            priority: block.task.priority,
            dueAt: dueAt,
            tagNames: block.task.tags.map(\.name),
            tagColorHex: block.task.tags.first?.color,
            isCompleted: isCompleted,
            isOverdue: isOverdue,
            isUnscheduled: false
        )
    }
}

func makePlanDaySections(
    items: [PlanTimelineItem],
    range: PlanVisibleRange,
    calendar: Calendar = .current
) -> [PlanDaySection] {
    let grouped = Dictionary(grouping: items, by: { calendar.startOfDay(for: $0.date) })
    var sections: [PlanDaySection] = []
    var day = calendar.startOfDay(for: range.start)
    let end = calendar.startOfDay(for: range.end)

    while day < end {
        let dayItems = (grouped[day] ?? [])
            .sorted(by: planTimelineItemComesFirst)
        sections.append(PlanDaySection(date: day, items: dayItems))
        day = calendar.date(byAdding: .day, value: 1, to: day) ?? end
    }

    return sections
}

func makePlanCalendarDensity(
    sections: [PlanDaySection],
    tasks: [TaskDTO],
    now: Date = .now,
    calendar: Calendar = .current
) -> [PlanCalendarDensity] {
    let dueGrouped = Dictionary(grouping: tasks.compactMap { task -> Date? in
        guard let dueDate = Date.fromISO8601(task.dueAt),
              task.status != .done,
              task.status != .archived else {
            return nil
        }
        return calendar.startOfDay(for: dueDate)
    }, by: { $0 })

    return sections.map { section in
        let dueCount = dueGrouped[calendar.startOfDay(for: section.date)]?.count ?? 0
        let hasUrgent = section.items.contains(where: { $0.priority == .urgent || $0.isOverdue })
        return PlanCalendarDensity(
            date: section.date,
            scheduledCount: section.items.count,
            dueCount: dueCount,
            hasUrgent: hasUrgent
        )
    }
}

func makeUnscheduledTasks(from tasks: [TaskDTO]) -> [TaskDTO] {
    tasks
        .filter { task in
            task.status != .archived &&
            task.archivedAt == nil &&
            ((task.timeBlocks ?? []).isEmpty)
        }
        .sorted(by: unscheduledTaskComesFirst)
}

private func planTimelineItemComesFirst(_ lhs: PlanTimelineItem, _ rhs: PlanTimelineItem) -> Bool {
    if lhs.isAllDay != rhs.isAllDay {
        return lhs.isAllDay && !rhs.isAllDay
    }

    switch (lhs.startAt, rhs.startAt) {
    case let (lhs?, rhs?) where lhs != rhs:
        return lhs < rhs
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        break
    }

    if lhs.priority != rhs.priority {
        return lhs.priority.sortRank > rhs.priority.sortRank
    }

    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
}

private func unscheduledTaskComesFirst(_ lhs: TaskDTO, _ rhs: TaskDTO) -> Bool {
    if lhs.isPinned != rhs.isPinned {
        return lhs.isPinned && !rhs.isPinned
    }

    if lhs.priority != rhs.priority {
        return lhs.priority.sortRank > rhs.priority.sortRank
    }

    let lhsDue = Date.fromISO8601(lhs.dueAt)
    let rhsDue = Date.fromISO8601(rhs.dueAt)

    switch (lhsDue, rhsDue) {
    case let (lhs?, rhs?) where lhs != rhs:
        return lhs < rhs
    case (_?, nil):
        return true
    case (nil, _?):
        return false
    default:
        break
    }

    if lhs.sortOrder != rhs.sortOrder {
        return lhs.sortOrder < rhs.sortOrder
    }

    return lhs.createdAt < rhs.createdAt
}
