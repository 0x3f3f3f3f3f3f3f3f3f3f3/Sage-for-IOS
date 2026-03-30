import SwiftUI

struct PlanPreviewSurface: View {
    @ObservedObject var manager: PlanTimelineManager

    var body: some View {
        ZStack {
            SagePalette.groupedBackground
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !manager.unscheduledTasks.isEmpty {
                    PlanUnscheduledTasksSection(
                        tasks: manager.unscheduledTasks,
                        language: manager.language,
                        onTapTask: { task in
                            manager.presentPlacement(for: task)
                        }
                    )
                }

                if manager.isLoading && manager.sections.isEmpty {
                    LoadingStateView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = manager.errorMessage, manager.sections.isEmpty {
                    ErrorStateView(message: errorMessage, retry: {
                        Task { @MainActor in
                            await manager.reloadVisibleRange()
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PlanTimelineView(manager: manager)
                }
            }

            VStack {
                PlanFromTodayPopupView(listScrollState: manager.listScrollState, language: manager.language)
                    .padding(.top, 12)
                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    PlanScrollBackToTodayButton(
                        listScrollState: manager.listScrollState,
                        language: manager.language
                    ) {
                        manager.scrollToToday()
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 32)
                }
            }
        }
        .overlay(
            PlanResizingOverlayView(pageState: manager.pageState)
                .allowsHitTesting(false)
        )
    }
}
