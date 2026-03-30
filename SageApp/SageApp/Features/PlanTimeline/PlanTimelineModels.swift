import Foundation

enum PlanTimelinePage: Int, CaseIterable, Hashable {
    case yearlyCalendar = 0
    case monthlyCalendar = 1
    case list = 2
}

struct PlanVisibleRange: Hashable {
    let start: Date
    let end: Date

    static func year(_ year: Int, calendar: Calendar = .current) -> PlanVisibleRange {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .now
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? start
        return PlanVisibleRange(start: start, end: end)
    }
}

struct PlanTimelineItem: Identifiable, Hashable {
    let id: String
    let taskId: String
    let timeBlockId: String?
    let subTaskId: String?
    let date: Date
    let startAt: Date?
    let endAt: Date?
    let isAllDay: Bool
    let title: String
    let subtitle: String
    let status: TaskStatus
    let priority: TaskPriority
    let dueAt: Date?
    let tagNames: [String]
    let tagColorHex: String?
    let isCompleted: Bool
    let isOverdue: Bool
    let isUnscheduled: Bool
}

struct PlanDaySection: Identifiable, Hashable {
    let date: Date
    let items: [PlanTimelineItem]

    var id: String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

struct PlanCalendarDensity: Hashable {
    let date: Date
    let scheduledCount: Int
    let dueCount: Int
    let hasUrgent: Bool
}

struct PlanSelectionState: Hashable {
    var selectedDate: Date
    var visibleMonth: Date
    var visibleYear: Int
}
