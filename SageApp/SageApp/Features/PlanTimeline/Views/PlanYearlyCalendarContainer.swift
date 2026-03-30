import SwiftUI

struct PlanYearlyCalendarContainer: View {
    @ObservedObject var manager: PlanTimelineManager

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("\(manager.visibleYear)")
                    .font(.title3.weight(.semibold))
                Spacer()
                headerButton(systemName: "chevron.left") {
                    manager.jumpToYear(manager.visibleYear - 1)
                }
                headerButton(systemName: "chevron.right") {
                    manager.jumpToYear(manager.visibleYear + 1)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(monthStarts, id: \.self) { monthStart in
                    Button {
                        manager.jumpToMonth(monthStart)
                        manager.pageState.scroll(to: .monthlyCalendar)
                    } label: {
                        monthCard(monthStart)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .background(SagePalette.groupedBackground)
    }

    private var monthStarts: [Date] {
        (1...12).compactMap { month in
            Calendar.current.date(from: DateComponents(year: manager.visibleYear, month: month, day: 1))
        }
    }

    @ViewBuilder
    private func monthCard(_ monthStart: Date) -> some View {
        let densities = manager.calendarDensity.filter {
            Calendar.current.isDate($0.date, equalTo: monthStart, toGranularity: .month)
        }
        let scheduled = densities.reduce(0) { $0 + $1.scheduledCount }
        let due = densities.reduce(0) { $0 + $1.dueCount }
        let hasUrgent = densities.contains(where: \.hasUrgent)

        VStack(alignment: .leading, spacing: 8) {
            Text(monthStart.formatted(.dateTime.month(.wide)))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Label("\(scheduled)", systemImage: "calendar")
                Label("\(due)", systemImage: "flag")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if hasUrgent {
                Text(localizedAppText(for: manager.language, chinese: "含紧急项", english: "Has urgent"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(SagePalette.separator)
        )
    }

    private func headerButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
        }
        .buttonStyle(.plain)
    }
}
