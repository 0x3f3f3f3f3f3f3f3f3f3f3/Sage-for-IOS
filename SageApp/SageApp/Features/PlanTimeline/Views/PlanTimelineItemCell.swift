import SwiftUI

struct PlanTimelineItemCell: View {
    let item: PlanTimelineItem
    let language: AppLanguage

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accentColor)
                .frame(width: 5, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if item.isOverdue {
                        Text(localizedAppText(for: language, chinese: "逾期", english: "Overdue"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(statusText)
                    Text(priorityText)
                    if let dueAt = item.dueAt {
                        Text(dueAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    if !item.tagNames.isEmpty {
                        Text(item.tagNames.prefix(2).joined(separator: " · "))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.isCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 2)
    }

    private var accentColor: Color {
        if let hex = item.tagColorHex {
            return Color(hex: hex)
        }
        switch item.priority {
        case .urgent:
            return .red
        case .high:
            return SagePalette.brand
        case .medium:
            return .pink
        case .low:
            return .teal
        }
    }

    private var statusText: String {
        switch item.status {
        case .done:
            return localizedAppText(for: language, chinese: "已完成", english: "Done")
        case .doing:
            return localizedAppText(for: language, chinese: "进行中", english: "Doing")
        case .todo, .inbox:
            return localizedAppText(for: language, chinese: "待办", english: "Todo")
        case .archived:
            return localizedAppText(for: language, chinese: "已归档", english: "Archived")
        }
    }

    private var priorityText: String {
        switch item.priority {
        case .urgent:
            return localizedAppText(for: language, chinese: "紧急", english: "Urgent")
        case .high:
            return localizedAppText(for: language, chinese: "高", english: "High")
        case .medium:
            return localizedAppText(for: language, chinese: "中", english: "Medium")
        case .low:
            return localizedAppText(for: language, chinese: "低", english: "Low")
        }
    }
}
