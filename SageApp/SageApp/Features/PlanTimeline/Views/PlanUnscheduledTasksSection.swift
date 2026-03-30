import SwiftUI

struct PlanUnscheduledTasksSection: View {
    let tasks: [TaskDTO]
    let language: AppLanguage
    let onTapTask: (TaskDTO) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localizedAppText(for: language, chinese: "未安排", english: "Unscheduled"))
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(tasks.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(tasks) { task in
                        Button {
                            onTapTask(task)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)

                                HStack(spacing: 6) {
                                    Text(localizedPriority(task.priority))
                                    if let dueAt = Date.fromISO8601(task.dueAt) {
                                        Text(dueAt.formatted(date: .abbreviated, time: .omitted))
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            }
                            .frame(width: 172, alignment: .leading)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(Color(uiColor: .secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(SagePalette.separator)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func localizedPriority(_ priority: TaskPriority) -> String {
        switch priority {
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
