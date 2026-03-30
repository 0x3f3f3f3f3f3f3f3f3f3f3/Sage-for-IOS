import SwiftUI

struct PlanTimelineView: View {
    @ObservedObject var manager: PlanTimelineManager

    var body: some View {
        HStack(spacing: 0) {
            PlanMonthYearSideBar(
                currentDate: manager.listScrollState.currentDate,
                language: manager.language,
                onPreviousMonth: {
                    if let previousMonth = Calendar.current.date(byAdding: .month, value: -1, to: manager.visibleMonth) {
                        manager.jumpToMonth(previousMonth)
                    }
                },
                onNextMonth: {
                    if let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: manager.visibleMonth) {
                        manager.jumpToMonth(nextMonth)
                    }
                }
            )

            PlanTimelineListRepresentable(
                sections: manager.sections,
                selectedDate: manager.selectedDate,
                language: manager.language,
                listScrollState: manager.listScrollState,
                onTapItem: { item in
                    manager.handleTap(on: item)
                },
                onTapEmptyDate: { date in
                    manager.presentPlacement(for: date)
                }
            )
        }
        .background(SagePalette.groupedBackground)
    }
}
