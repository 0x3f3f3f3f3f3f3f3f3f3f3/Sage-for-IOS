import SwiftUI

@MainActor
struct PlanTimelineHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @StateObject private var manager = PlanTimelineManager()
    @State private var selectedBlock: TimeBlockDTO?
    @State private var placementContext: TimelinePlacementContext?

    var body: some View {
        GeometryReader { geometry in
            let pageWidth = geometry.size.width

            ZStack {
                SagePalette.groupedBackground
                    .ignoresSafeArea()

                HStack(spacing: 0) {
                    PlanYearlyCalendarContainer(manager: manager)
                        .frame(width: pageWidth)

                    PlanMonthlyCalendarContainer(manager: manager)
                        .frame(width: pageWidth)

                    PlanPreviewSurface(manager: manager)
                        .frame(width: pageWidth)
                }
                .frame(width: pageWidth * CGFloat(PlanTimelinePage.allCases.count), alignment: .leading)
                .offset(x: -CGFloat(manager.pageState.activePage.rawValue) * pageWidth + manager.pageState.translation)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            manager.pageState.updatePageWidth(pageWidth)
                            manager.pageState.horizontalDragChanged(value)
                        }
                        .onEnded { value in
                            manager.pageState.horizontalDragEnded(value)
                        },
                    including: manager.pageState.canDrag ? .all : .subviews
                )
            }
        }
        .navigationTitle(localizedAppText(for: settings.language, chinese: "规划", english: "Plan"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            manager.language = settings.language
            await manager.initialLoad(using: environment)
        }
        .onChange(of: settings.language) { _, newLanguage in
            manager.language = newLanguage
        }
        .sheet(item: $selectedBlock) { block in
            TimeBlockEditorSheet(task: manager.tasks.first(where: { $0.id == block.taskId }), existing: block) { updated in
                manager.ingestUpdatedBlock(updated)
            } onDelete: {
                manager.removeBlockLocally(id: block.id)
            }
        }
        .sheet(item: $placementContext) { context in
            TimelinePlacementSheet(context: context) { saved in
                manager.ingestCreatedBlock(saved)
            }
        }
        .onAppear {
            manager.pageState.scroll(to: .list)
        }
        .onChange(of: manager.pageState.activePage) { _, page in
            if page == .list {
                manager.listScrollState.scroll(to: manager.selectedDate, animated: false)
            }
        }
        .modifier(PlanSheetBridge(manager: manager, selectedBlock: $selectedBlock, placementContext: $placementContext))
    }
}

private struct PlanSheetBridge: ViewModifier {
    @ObservedObject var manager: PlanTimelineManager
    @Binding var selectedBlock: TimeBlockDTO?
    @Binding var placementContext: TimelinePlacementContext?

    func body(content: Content) -> some View {
        content
            .onAppear {
                manager.onScheduledItemTap = { item in
                    guard let blockID = item.timeBlockId,
                          let block = manager.blocks.first(where: { $0.id == blockID }) else {
                        return
                    }
                    selectedBlock = TimeBlockDTO(
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
                }
                manager.onPlacementRequested = { context in
                    placementContext = context
                }
            }
    }
}
