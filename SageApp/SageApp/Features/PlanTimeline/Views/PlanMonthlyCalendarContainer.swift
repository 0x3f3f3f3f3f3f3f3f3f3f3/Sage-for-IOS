import SwiftUI

struct PlanMonthlyCalendarContainer: View {
    @ObservedObject var manager: PlanTimelineManager

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(monthTitle)
                    .font(.title3.weight(.semibold))
                Spacer()
                headerButton(systemName: "chevron.left") {
                    if let previous = Calendar.current.date(byAdding: .month, value: -1, to: manager.visibleMonth) {
                        manager.jumpToMonth(previous)
                    }
                }
                headerButton(systemName: "calendar") {
                    manager.scrollToToday()
                }
                headerButton(systemName: "chevron.right") {
                    if let next = Calendar.current.date(byAdding: .month, value: 1, to: manager.visibleMonth) {
                        manager.jumpToMonth(next)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ForEach(monthGridDates, id: \.self) { date in
                    if let date {
                        Button {
                            manager.select(date: date)
                            manager.pageState.scroll(to: .list)
                        } label: {
                            monthDayCell(date)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 44)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .background(SagePalette.groupedBackground)
    }

    private var monthTitle: String {
        manager.visibleMonth.formatted(.dateTime.month(.wide).year())
    }

    private var weekdaySymbols: [String] {
        let language = manager.language
        return language == .chineseSimplified
            ? ["日", "一", "二", "三", "四", "五", "六"]
            : Calendar.current.shortStandaloneWeekdaySymbols
    }

    private var monthGridDates: [Date?] {
        let calendar = Calendar.current
        let startOfMonth = manager.visibleMonth
        let range = calendar.range(of: .day, in: .month, for: startOfMonth) ?? 1..<29
        let weekday = calendar.component(.weekday, from: startOfMonth)
        let leading = max(0, weekday - calendar.firstWeekday)

        var dates = Array(repeating: Optional<Date>.none, count: leading < 0 ? leading + 7 : leading)
        dates += range.compactMap { day -> Date? in
            let components = calendar.dateComponents([.year, .month], from: startOfMonth)
            return calendar.date(from: DateComponents(year: components.year, month: components.month, day: day))
        }
        while dates.count % 7 != 0 {
            dates.append(nil)
        }
        return dates
    }

    @ViewBuilder
    private func monthDayCell(_ date: Date) -> some View {
        let density = manager.density(for: date)
        let isSelected = Calendar.current.isDate(date, inSameDayAs: manager.selectedDate)
        VStack(spacing: 4) {
            Text(date.formatted(.dateTime.day()))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .primary)

            HStack(spacing: 3) {
                Circle()
                    .fill(density.hasUrgent ? .red : SagePalette.brand)
                    .frame(width: 5, height: 5)
                if density.scheduledCount > 0 {
                    Text("\(density.scheduledCount)")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? SagePalette.brand : Color(uiColor: .secondarySystemBackground))
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
