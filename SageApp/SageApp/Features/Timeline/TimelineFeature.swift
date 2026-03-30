import SwiftUI
import Observation
#if canImport(UIKit)
import UIKit
#endif

enum TimelineMode: String, CaseIterable, Hashable, Identifiable {
    case week
    case month

    var id: String { rawValue }
}

private enum PlanDataState: Equatable {
    case idle
    case loading
    case loaded
    case failedLoad(String)
}

private enum PlanLoadResult: Equatable {
    case success
    case failed(String)
    case refreshedWithExistingData(String)
}

private enum PlanTransientFeedback: Equatable {
    case none
    case toast(String)
    case banner(String)
}

private enum PlanDropTarget: Equatable {
    case allDay
    case timed(minutes: Int)
}

@MainActor
@Observable
final class TimelineViewModel {
    var blocks: [TimelineBlockDTO] = []
    var tasks: [TaskDTO] = []
    var mode: TimelineMode = .week
    var anchorDate = Date()
    fileprivate var dataState: PlanDataState = .idle

    fileprivate func load(using api: APIClient) async -> PlanLoadResult {
        let hadCachedContent = !blocks.isEmpty || !tasks.isEmpty || dataState == .loaded
        if !hadCachedContent {
            dataState = .loading
        }

        do {
            let range = dateRange
            let formatter = DateFormatter.makeOffsetISO8601()
            let timelinePath = makeAPIPath(
                "/api/mobile/v1/timeline",
                queryItems: [
                    URLQueryItem(name: "start", value: formatter.string(from: range.start)),
                    URLQueryItem(name: "end", value: formatter.string(from: range.end))
                ]
            )
            async let blocksRequest: [TimelineBlockDTO] = api.send(path: timelinePath)
            async let tasksRequest: [TaskDTO] = api.send(path: "/api/mobile/v1/tasks")
            blocks = try await blocksRequest
            tasks = try await tasksRequest
            dataState = .loaded
            return .success
        } catch {
            let message = error.localizedDescription
            if hadCachedContent {
                dataState = .loaded
                return .refreshedWithExistingData(message)
            } else {
                dataState = .failedLoad(message)
                return .failed(message)
            }
        }
    }

    var dateRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchorDate)
        let displayEnd: Date

        switch mode {
        case .week:
            displayEnd = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        case .month:
            displayEnd = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        }

        let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: displayEnd)) ?? displayEnd
        return (start, exclusiveEnd)
    }

    var displayEndDate: Date {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: anchorDate)

        switch mode {
        case .week:
            return calendar.date(byAdding: .day, value: 7, to: start) ?? start
        case .month:
            return calendar.date(byAdding: .month, value: 1, to: start) ?? start
        }
    }
}

@MainActor
struct TimelineScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = TimelineViewModel()
    @State private var selectedBlock: TimelineBlockDTO?
    @State private var placementContext: TimelinePlacementContext?
    @State private var plannerFrames: [String: CGRect] = [:]
    @State private var dragState: PlannerDragState?
    @State private var interactionMode: PlanInteractionState = .idle
    @State private var transientFeedback: PlanTransientFeedback = .none
    @State private var feedbackDismissTask: Task<Void, Never>?
    @State private var showingDatePicker = false
    @State private var isTaskTrayExpanded = false

    private let hourHeight: CGFloat = 64
    private let timeAxisWidth: CGFloat = 46

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlanPagePalette.canvas
                .ignoresSafeArea()

            HStack(spacing: 0) {
                dayRail

                VStack(spacing: 0) {
                    plannerHeader
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 10)

                    if let bannerMessage = bannerMessage {
                        PlanTransientFeedbackView(message: bannerMessage, style: .banner)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 10)
                    }

                    if let blockingErrorMessage {
                        ErrorStateView(message: blockingErrorMessage, retry: {
                            Task { @MainActor in
                                await reload()
                            }
                        })
                        .padding(.horizontal, 18)
                        .padding(.top, 8)
                    } else if isBlockingLoad {
                        LoadingStateView()
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                    } else {
                        VStack(spacing: 0) {
                            allDayLane
                            plannerGrid
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(PlanPagePalette.surface)
                .safeAreaInset(edge: .bottom) {
                    taskTray
                }
            }
            .background(PlanPagePalette.timelineSurface)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(PlanPagePalette.shellStroke, lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .coordinateSpace(name: "planner")
            .onPreferenceChange(PlannerFramePreferenceKey.self) { plannerFrames = $0 }

            if let dragState {
                plannerDragGhost(dragState)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(colorScheme == .dark ? .dark : .light, for: .navigationBar)
        .task(id: reloadKey) {
            await reload()
        }
        .sheet(item: $selectedBlock) { block in
            TimelineBlockInspectorSheet(block: block) {
                Task { @MainActor in
                    await reload()
                }
            }
        }
        .sheet(item: $placementContext) { context in
            TimelinePlacementSheet(context: context) { _ in
                Task { @MainActor in
                    await reload()
                }
            }
        }
        .sheet(isPresented: $showingDatePicker) {
            NavigationStack {
                VStack(spacing: 20) {
                    DatePicker(
                        localizedAppText(for: settings.language, chinese: "选择日期", english: "Select date"),
                        selection: Binding(
                            get: { selectedDay },
                            set: { viewModel.anchorDate = $0 }
                        ),
                        displayedComponents: [.date]
                    )
                    .datePickerStyle(.graphical)
                    .padding()

                    GlassPrimaryButton(
                        title: LocalizedStringKey(localizedAppText(for: settings.language, chinese: "今天", english: "Today")),
                        systemName: "calendar.badge.clock"
                    ) {
                        viewModel.anchorDate = Date()
                        showingDatePicker = false
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .navigationTitle(localizedAppText(for: settings.language, chinese: "日历", english: "Calendar"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.done") {
                            showingDatePicker = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .refreshable {
            await reload()
        }
        .overlay(alignment: .bottom) {
            if let toastMessage = toastMessage {
                PlanTransientFeedbackView(message: toastMessage, style: .toast)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 108)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var selectedDay: Date {
        Calendar.current.startOfDay(for: viewModel.anchorDate)
    }

    private var dayRailDays: [Date] {
        let calendar = Calendar.current
        return (-3...3).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: selectedDay)
        }
    }

    private var selectedAssignments: [TimelineBlockDTO] {
        viewModel.blocks
            .filter { $0.isAllDay && blockMatchesDay($0, day: selectedDay) }
            .sorted(by: assignmentComesFirst)
    }

    private var selectedTimedBlocks: [TimelineBlockDTO] {
        viewModel.blocks
            .filter { !$0.isAllDay && blockMatchesDay($0, day: selectedDay) }
            .sorted(by: timedBlockComesFirst)
    }

    private var candidateTasks: [TaskDTO] {
        viewModel.tasks
            .filter { task in
                task.status != .done && task.status != .archived
            }
            .sorted(by: candidateTaskComesFirst)
    }

    private var reloadKey: String {
        "\(Calendar.current.startOfDay(for: viewModel.anchorDate).timeIntervalSinceReferenceDate)"
    }

    private func reload() async {
        let result = await viewModel.load(using: environment.apiClient)
        if case .refreshedWithExistingData = result {
            showBanner(localizedTimelineText(chinese: "无法刷新规划内容。", english: "Couldn’t refresh plan."))
        }
    }

    private func blockMatchesDay(_ block: TimelineBlockDTO, day: Date) -> Bool {
        guard let start = Date.fromISO8601(block.startAt) else { return false }
        return Calendar.current.isDate(start, inSameDayAs: day)
    }

    private func blockTimeRange(_ block: TimelineBlockDTO) -> String {
        let start = Date.fromISO8601(block.startAt)?.formatted(date: .omitted, time: .shortened) ?? block.startAt
        let end = Date.fromISO8601(block.endAt)?.formatted(date: .omitted, time: .shortened) ?? block.endAt
        return "\(start) - \(end)"
    }

    private func assignmentComesFirst(_ lhs: TimelineBlockDTO, _ rhs: TimelineBlockDTO) -> Bool {
        if lhs.originTimeBlockId != rhs.originTimeBlockId {
            return lhs.originTimeBlockId == nil
        }

        let lhsTitle = timelineAssignmentTitle(for: lhs)
        let rhsTitle = timelineAssignmentTitle(for: rhs)
        return lhsTitle < rhsTitle
    }

    private func timedBlockComesFirst(_ lhs: TimelineBlockDTO, _ rhs: TimelineBlockDTO) -> Bool {
        let lhsDate = Date.fromISO8601(lhs.startAt)
        let rhsDate = Date.fromISO8601(rhs.startAt)

        switch (lhsDate, rhsDate) {
        case let (lhsDate?, rhsDate?):
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }
            return lhs.createdAt < rhs.createdAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func localizedTimelineText(chinese: String, english: String) -> String {
        localizedAppText(for: environment.settings.language, chinese: chinese, english: english)
    }

    private var isBlockingLoad: Bool {
        switch viewModel.dataState {
        case .idle, .loading:
            return viewModel.blocks.isEmpty && viewModel.tasks.isEmpty
        case .loaded, .failedLoad:
            return false
        }
    }

    private var blockingErrorMessage: String? {
        guard case let .failedLoad(message) = viewModel.dataState else { return nil }
        return message
    }

    private var bannerMessage: String? {
        guard case let .banner(message) = transientFeedback else { return nil }
        return message
    }

    private var toastMessage: String? {
        guard case let .toast(message) = transientFeedback else { return nil }
        return message
    }

    private func timelineAssignmentTitle(for block: TimelineBlockDTO) -> String {
        if let subTaskId = block.subTaskId,
           let subtask = block.task.subtasks.first(where: { $0.id == subTaskId }) {
            return subtask.title
        }

        return block.task.title
    }

    private var dayRail: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)

            VStack(spacing: 10) {
                ForEach(dayRailDays, id: \.self) { day in
                    dayRailCell(day)
                }
            }

            Spacer(minLength: 18)
        }
        .frame(width: 62)
        .background(PlanPagePalette.rail)
        .overlay(alignment: .bottomLeading) {
            Text(selectedDay.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(5)
                .foregroundStyle(PlanPagePalette.railSecondaryText)
                .rotationEffect(.degrees(-90))
                .offset(x: -4, y: -26)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(PlanPagePalette.separator)
                .frame(width: 1)
        }
    }

    private func dayRailCell(_ day: Date) -> some View {
        let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDay)
        let hasLoad = dayLoad(for: day) > 0

        return Button {
            viewModel.anchorDate = day
        } label: {
            VStack(spacing: 3) {
                Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(isSelected ? PlanPagePalette.railPrimaryText : PlanPagePalette.railSecondaryText)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(isSelected ? PlanPagePalette.railPrimaryText : PlanPagePalette.railMutedText)
                Circle()
                    .fill(isSelected ? SagePalette.brand : PlanPagePalette.railPrimaryText.opacity(hasLoad ? 0.86 : 0.18))
                    .frame(width: 4, height: 4)
                    .opacity(hasLoad || isSelected ? 1 : 0)
            }
            .frame(width: 44, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(colorScheme == .dark ? 0.08 : 0.10) : Color.clear)
            )
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(isSelected ? SagePalette.brand : Color.clear)
                    .frame(width: 2, height: 22)
                    .offset(x: -2)
            }
        }
        .buttonStyle(.plain)
    }

    private var plannerHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localizedTimelineText(chinese: "规划", english: "Plan").uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(PlanPagePalette.tertiaryText)

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedDay.formatted(.dateTime.weekday(.wide)))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(PlanPagePalette.primaryText)
                    Text(selectedDay.formatted(.dateTime.month(.wide).day().year()))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PlanPagePalette.secondaryText)
                }

                Spacer(minLength: 8)

                Button(localizedTimelineText(chinese: "今天", english: "Today")) {
                    viewModel.anchorDate = Date()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PlanPagePalette.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(PlanPagePalette.buttonFill)
                )

                HStack(spacing: 6) {
                    plannerHeaderIcon(systemName: "chevron.left") {
                        viewModel.anchorDate = Calendar.current.date(byAdding: .day, value: -1, to: viewModel.anchorDate) ?? viewModel.anchorDate
                    }

                    plannerHeaderIcon(systemName: "chevron.right") {
                        viewModel.anchorDate = Calendar.current.date(byAdding: .day, value: 1, to: viewModel.anchorDate) ?? viewModel.anchorDate
                    }

                    plannerHeaderIcon(systemName: "calendar") {
                        showingDatePicker = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func plannerHeaderIcon(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .foregroundStyle(PlanPagePalette.primaryText)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PlanPagePalette.buttonFill)
        )
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var allDayLane: some View {
        let isTargeted = isLaneTargeted
        let visibleAssignments = Array(selectedAssignments.prefix(3))
        let overflowCount = max(0, selectedAssignments.count - visibleAssignments.count)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localizedTimelineText(chinese: "全天", english: "All-day"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PlanPagePalette.primaryText)
                Text("\(selectedAssignments.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PlanPagePalette.secondaryText)
                Spacer()
                if isTaskDragActive {
                    Text(localizedTimelineText(chinese: "松手创建全天安排", english: "Drop to make all-day"))
                        .font(.caption2)
                        .foregroundStyle(PlanPagePalette.secondaryText)
                }
            }

            if !visibleAssignments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(visibleAssignments) { assignment in
                            Button {
                                selectedBlock = assignment
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(assignment.originTimeBlockId == nil ? SagePalette.brand : Color.teal)
                                        .frame(width: 6, height: 6)
                                    Text(timelineAssignmentTitle(for: assignment))
                                        .lineLimit(1)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PlanPagePalette.primaryText)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(PlanPagePalette.chipFill)
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if overflowCount > 0 {
                            Text("+\(overflowCount)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PlanPagePalette.secondaryText)
                                .padding(.horizontal, 10)
                                .frame(height: 28)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(PlanPagePalette.chipFill)
                                )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(isTargeted ? PlanPagePalette.selectionFill : PlanPagePalette.surfaceOverlay)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isTargeted ? SagePalette.brand.opacity(0.45) : PlanPagePalette.separator)
                .frame(height: 1)
        }
        .plannerFrame("allDayLane")
    }

    private var plannerGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            Color.clear
                                .frame(height: 0)
                                .plannerFrame("gridContent")

                            ForEach(0..<24, id: \.self) { hour in
                                HStack(spacing: 0) {
                                    Text(String(format: "%02d:00", hour))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(PlanPagePalette.tertiaryText)
                                        .frame(width: timeAxisWidth, alignment: .trailing)
                                        .padding(.trailing, 8)

                                    Rectangle()
                                        .fill(PlanPagePalette.separator)
                                        .frame(width: 1)

                                    VStack(spacing: 0) {
                                        Rectangle()
                                            .fill(PlanPagePalette.separator)
                                            .frame(height: 1)
                                        Spacer(minLength: 0)
                                        Rectangle()
                                            .fill(PlanPagePalette.separator.opacity(0.55))
                                            .frame(height: 1)
                                    }
                                    .frame(height: hourHeight)
                                }
                                .background(hour.isMultiple(of: 2) ? PlanPagePalette.surface : PlanPagePalette.surfaceAlt)
                                .id("hour-\(hour)")
                            }
                        }

                        ForEach(selectedTimedBlocks) { block in
                            PlannerTimelineBlockCard(
                                block: block,
                                baseHeight: blockHeight(block),
                                language: settings.language,
                                title: block.task.title,
                                subtitle: deploymentTargetTitle(for: block.task, subTaskId: block.subTaskId, language: settings.language),
                                isActive: interactionMode.matches(blockID: block.id),
                                onTap: { selectedBlock = block },
                                onMoveChanged: { location in
                                    interactionMode = .movingBlock(block.id)
                                    dragState = PlannerDragState(
                                        title: block.task.title,
                                        source: .block(block),
                                        currentLocation: location
                                    )
                                },
                                onMoveEnded: { location in
                                    let movedBlock = block
                                    dragState = nil
                                    interactionMode = .idle
                                    Task { @MainActor in
                                        await move(block: movedBlock, to: location)
                                    }
                                },
                                onResizeChanged: { _ in
                                    interactionMode = .resizingBlock(block.id)
                                },
                                onResizeEnded: { delta in
                                    interactionMode = .idle
                                    Task { @MainActor in
                                        await resize(block: block, deltaHeight: delta)
                                    }
                                }
                            )
                            .frame(width: geometry.size.width - timeAxisWidth - 18)
                            .offset(x: timeAxisWidth + 12, y: blockOffsetY(block))
                        }

                        if let dragPreview {
                            PlanPlacementPreviewView(title: dragPreview.title, subtitle: dragPreview.subtitle)
                                .frame(width: geometry.size.width - timeAxisWidth - 18)
                                .frame(height: dragPreview.height)
                                .offset(x: timeAxisWidth + 12, y: dragPreview.offsetY)
                                .allowsHitTesting(false)
                        }

                        if Calendar.current.isDateInToday(selectedDay) {
                            Rectangle()
                                .fill(SagePalette.brand)
                                .frame(height: 2)
                                .overlay(alignment: .leading) {
                                    Circle()
                                        .fill(SagePalette.brand)
                                        .frame(width: 10, height: 10)
                                        .offset(x: -5)
                                }
                                .frame(width: geometry.size.width - timeAxisWidth - 18)
                                .offset(x: timeAxisWidth + 12, y: currentTimeOffsetY())
                        }

                    }
                }
                .frame(height: hourHeight * 24)
                .plannerFrame("gridViewport")
            }
            .background(PlanPagePalette.surface)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PlanPagePalette.separator)
                    .frame(height: 1)
            }
            .onAppear {
                let targetHour = initialScrollHour(for: selectedDay)
                DispatchQueue.main.async {
                    proxy.scrollTo("hour-\(targetHour)", anchor: .top)
                }
            }
            .onChange(of: selectedDay) { _, day in
                let targetHour = initialScrollHour(for: day)
                DispatchQueue.main.async {
                    proxy.scrollTo("hour-\(targetHour)", anchor: .top)
                }
            }
        }
    }

    private var taskTray: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localizedTimelineText(chinese: "待规划任务", english: "Task tray"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PlanPagePalette.primaryText)
                Text("\(candidateTasks.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PlanPagePalette.secondaryText)
                Spacer()
                if isTaskDragActive {
                    Text(localizedTimelineText(chinese: "长按后拖到时间轴", english: "Long press, then drag"))
                        .font(.caption2)
                        .foregroundStyle(PlanPagePalette.secondaryText)
                }
                Button {
                    let animation: Animation? = reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.9)
                    withAnimation(animation) {
                        isTaskTrayExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isTaskTrayExpanded ? "chevron.down" : "chevron.up")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32)
                }
                .foregroundStyle(PlanPagePalette.primaryText)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(PlanPagePalette.buttonFill)
                )
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(candidateTasks) { task in
                        PlannerTaskChip(
                            task: task,
                            scheduledMinutes: scheduledMinutes(for: task),
                            language: settings.language,
                            isExpanded: isTaskTrayExpanded,
                            onDragChanged: { location in
                                interactionMode = .draggingTrayTask(task.id)
                                dragState = PlannerDragState(
                                    title: task.title,
                                    source: .task(task),
                                    currentLocation: location
                                )
                            },
                            onDragEnded: { location in
                                let draggedTask = task
                                dragState = nil
                                interactionMode = .idle
                                Task { @MainActor in
                                    await createFromTaskDrop(task: draggedTask, at: location)
                                }
                            }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(PlanPagePalette.trayFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(PlanPagePalette.shellStroke)
        )
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var currentDropTarget: PlanDropTarget? {
        guard let dragState else { return nil }
        if let allDayLane = plannerFrames["allDayLane"], allDayLane.contains(dragState.currentLocation) {
            return .allDay
        }
        if let snappedMinutes = snappedMinutes(for: dragState.currentLocation) {
            return .timed(minutes: snappedMinutes)
        }
        return nil
    }

    private var dragPreview: PlanGridPlacementPreview? {
        guard let dragState else { return nil }
        guard case let .timed(minutes) = currentDropTarget else { return nil }

        let title: String
        let subtitle: String
        let durationMinutes: Int

        switch dragState.source {
        case let .task(task):
            title = task.title
            subtitle = localizedTimelineText(chinese: "新的时间块", english: "New block")
            durationMinutes = 60
        case let .block(block):
            title = block.task.title
            subtitle = deploymentTargetTitle(for: block.task, subTaskId: block.subTaskId, language: settings.language)
            if let start = Date.fromISO8601(block.startAt),
               let end = Date.fromISO8601(block.endAt) {
                durationMinutes = max(15, Int(end.timeIntervalSince(start) / 60))
            } else {
                durationMinutes = 60
            }
        }

        return PlanGridPlacementPreview(
            title: title,
            subtitle: subtitle,
            height: max(48, CGFloat(durationMinutes) * (hourHeight / 60) - 4),
            offsetY: CGFloat(minutes) * (hourHeight / 60) + 2
        )
    }

    private func dayLoad(for day: Date) -> Int {
        viewModel.blocks.filter { blockMatchesDay($0, day: day) }.count
    }

    private func blockOffsetY(_ block: TimelineBlockDTO) -> CGFloat {
        guard let start = Date.fromISO8601(block.startAt) else {
            return 0
        }

        let startMinutes = minutesIntoDay(start)
        let minutesHeight = hourHeight / 60
        return CGFloat(startMinutes) * minutesHeight + 2
    }

    private func blockHeight(_ block: TimelineBlockDTO) -> CGFloat {
        guard let start = Date.fromISO8601(block.startAt),
              let end = Date.fromISO8601(block.endAt) else {
            return 50
        }

        let duration = max(15, Int(end.timeIntervalSince(start) / 60))
        return max(50, CGFloat(duration) * (hourHeight / 60) - 4)
    }

    private func currentTimeOffsetY() -> CGFloat {
        let minutes = minutesIntoDay(Date())
        return CGFloat(minutes) * (hourHeight / 60) + 2
    }

    private func scheduledMinutes(for task: TaskDTO) -> Int {
        viewModel.blocks
            .filter { $0.taskId == task.id && !$0.isAllDay }
            .compactMap { block -> Int? in
                guard let start = Date.fromISO8601(block.startAt),
                      let end = Date.fromISO8601(block.endAt) else {
                    return nil
                }
                return max(0, Int(end.timeIntervalSince(start) / 60))
            }
            .reduce(0, +)
    }

    private func candidateTaskComesFirst(_ lhs: TaskDTO, _ rhs: TaskDTO) -> Bool {
        switch (Date.fromISO8601(lhs.dueAt), Date.fromISO8601(rhs.dueAt)) {
        case let (lhs?, rhs?):
            if lhs != rhs {
                return lhs < rhs
            }
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            break
        }

        if lhs.priority != rhs.priority {
            return lhs.priority.sortRank > rhs.priority.sortRank
        }

        return lhs.createdAt < rhs.createdAt
    }

    private func minutesIntoDay(_ date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func snappedMinutes(for location: CGPoint) -> Int? {
        guard let gridViewport = plannerFrames["gridViewport"],
              let gridContent = plannerFrames["gridContent"],
              gridViewport.contains(location) else {
            return nil
        }

        let scrollOffset = gridViewport.minY - gridContent.minY
        let rawY = location.y - gridViewport.minY + scrollOffset
        let rawMinutes = max(0, min(24 * 60 - 15, Int((rawY / hourHeight) * 60)))
        let snapped = (rawMinutes / 15) * 15
        return snapped
    }

    private func initialScrollHour(for day: Date) -> Int {
        if Calendar.current.isDateInToday(day) {
            return max(0, Calendar.current.component(.hour, from: Date()) - 1)
        }
        return 8
    }

    private func createFromTaskDrop(task: TaskDTO, at location: CGPoint) async {
        if let allDayLane = plannerFrames["allDayLane"], allDayLane.contains(location) {
            await createBlock(for: task, minutes: 0, isAllDay: true)
            return
        }

        guard let snappedMinutes = snappedMinutes(for: location) else {
            PlanHaptics.selection()
            return
        }
        if task.subtasks.isEmpty {
            await createBlock(for: task, minutes: snappedMinutes, isAllDay: false)
        } else {
            placementContext = TimelinePlacementContext(
                availableTasks: [task],
                preselectedTaskID: task.id,
                preselectedDate: selectedDay,
                preferredMode: .timed,
                lockedSubTaskId: nil,
                lockTaskSelection: true,
                lockDeploymentTargetSelection: false
            )
        }
    }

    private func createBlock(for task: TaskDTO, minutes: Int, isAllDay: Bool) async {
        let start: Date
        let end: Date

        if isAllDay {
            start = Calendar.current.startOfDay(for: selectedDay)
            end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        } else {
            start = Calendar.current.date(byAdding: .minute, value: minutes, to: Calendar.current.startOfDay(for: selectedDay)) ?? selectedDay
            end = Calendar.current.date(byAdding: .minute, value: 60, to: start) ?? start
        }

        let request = TimeBlockWriteRequest(
            startAt: DateFormatter.makeOffsetISO8601().string(from: start),
            endAt: DateFormatter.makeOffsetISO8601().string(from: end),
            subTaskId: nil,
            isAllDay: isAllDay
        )
        let temporaryID = "temp-\(UUID().uuidString)"
        let timestamp = DateFormatter.makeOffsetISO8601().string(from: Date())
        let optimistic = TimeBlockDTO(
            id: temporaryID,
            taskId: task.id,
            startAt: request.startAt,
            endAt: request.endAt,
            subTaskId: nil,
            isAllDay: isAllDay,
            originTimeBlockId: nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        insertOrReplaceTimelineBlock(optimistic, task: task)

        do {
            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/tasks/\(task.id)/time-blocks",
                method: "POST",
                body: request
            )
            removeTimelineBlock(id: temporaryID)
            insertOrReplaceTimelineBlock(saved, task: task)
        } catch {
            removeTimelineBlock(id: temporaryID)
            showToast(localizedTimelineText(chinese: "无法创建时间块，请重试。", english: "Couldn’t create the time block. Please try again."))
            PlanHaptics.error()
        }
    }

    private func move(block: TimelineBlockDTO, to location: CGPoint) async {
        let start: Date
        let end: Date
        let isAllDay: Bool

        if let allDayLane = plannerFrames["allDayLane"], allDayLane.contains(location) {
            start = Calendar.current.startOfDay(for: selectedDay)
            end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            isAllDay = true
        } else if let snappedMinutes = snappedMinutes(for: location) {
            let currentDuration = max(15, Int((Date.fromISO8601(block.endAt)?.timeIntervalSince(Date.fromISO8601(block.startAt) ?? selectedDay) ?? 3600) / 60))
            start = Calendar.current.date(byAdding: .minute, value: snappedMinutes, to: Calendar.current.startOfDay(for: selectedDay)) ?? selectedDay
            end = Calendar.current.date(byAdding: .minute, value: currentDuration, to: start) ?? start
            isAllDay = false
        } else {
            PlanHaptics.selection()
            return
        }

        let original = block
        let optimistic = TimeBlockDTO(
            id: block.id,
            taskId: block.taskId,
            startAt: DateFormatter.makeOffsetISO8601().string(from: start),
            endAt: DateFormatter.makeOffsetISO8601().string(from: end),
            subTaskId: block.subTaskId,
            isAllDay: isAllDay,
            originTimeBlockId: block.originTimeBlockId,
            createdAt: block.createdAt,
            updatedAt: block.updatedAt
        )
        insertOrReplaceTimelineBlock(optimistic, task: block.task)

        do {
            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(block.id)",
                method: "PATCH",
                body: TimeBlockWriteRequest(
                    startAt: DateFormatter.makeOffsetISO8601().string(from: start),
                    endAt: DateFormatter.makeOffsetISO8601().string(from: end),
                    subTaskId: block.subTaskId,
                    isAllDay: isAllDay
                )
            )
            insertOrReplaceTimelineBlock(saved, task: block.task)
        } catch {
            insertOrReplaceTimelineBlock(original.asTimeBlockDTO, task: original.task)
            showToast(localizedTimelineText(chinese: "无法更新时间块，请重试。", english: "Couldn’t update the time block. Please try again."))
            PlanHaptics.error()
        }
    }

    private func resize(block: TimelineBlockDTO, deltaHeight: CGFloat) async {
        guard let start = Date.fromISO8601(block.startAt),
              let end = Date.fromISO8601(block.endAt) else {
            return
        }

        let minuteDelta = Int((deltaHeight / hourHeight) * 60)
        let snappedDelta = (minuteDelta / 15) * 15
        let currentDuration = max(15, Int(end.timeIntervalSince(start) / 60))
        let nextDuration = max(15, currentDuration + snappedDelta)
        let nextEnd = Calendar.current.date(byAdding: .minute, value: nextDuration, to: start) ?? end

        let original = block
        let optimistic = TimeBlockDTO(
            id: block.id,
            taskId: block.taskId,
            startAt: block.startAt,
            endAt: DateFormatter.makeOffsetISO8601().string(from: nextEnd),
            subTaskId: block.subTaskId,
            isAllDay: false,
            originTimeBlockId: block.originTimeBlockId,
            createdAt: block.createdAt,
            updatedAt: block.updatedAt
        )
        insertOrReplaceTimelineBlock(optimistic, task: block.task)

        do {
            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(block.id)",
                method: "PATCH",
                body: TimeBlockWriteRequest(
                    startAt: block.startAt,
                    endAt: DateFormatter.makeOffsetISO8601().string(from: nextEnd),
                    subTaskId: block.subTaskId,
                    isAllDay: false
                )
            )
            insertOrReplaceTimelineBlock(saved, task: block.task)
        } catch {
            insertOrReplaceTimelineBlock(original.asTimeBlockDTO, task: original.task)
            showToast(localizedTimelineText(chinese: "无法调整时长，请重试。", english: "Couldn’t resize the block. Please try again."))
            PlanHaptics.error()
        }
    }

    private func insertOrReplaceTimelineBlock(_ block: TimeBlockDTO, task: TaskDTO) {
        let timelineBlock = TimelineBlockDTO(
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

        if let index = viewModel.blocks.firstIndex(where: { $0.id == block.id }) {
            viewModel.blocks[index] = timelineBlock
        } else {
            viewModel.blocks.append(timelineBlock)
        }
    }

    private func removeTimelineBlock(id: String) {
        viewModel.blocks.removeAll { $0.id == id }
    }

    private func showToast(_ message: String) {
        setFeedback(.toast(message), autoDismissAfter: 2.4)
    }

    private func showBanner(_ message: String) {
        setFeedback(.banner(message), autoDismissAfter: 3.0)
    }

    private func setFeedback(_ feedback: PlanTransientFeedback, autoDismissAfter delay: Double) {
        feedbackDismissTask?.cancel()
        transientFeedback = feedback
        feedbackDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            if transientFeedback == feedback {
                transientFeedback = .none
            }
        }
    }

    @ViewBuilder
    private func plannerDragGhost(_ dragState: PlannerDragState) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(SagePalette.brand)
                .frame(width: 8, height: 8)

            Text(dragState.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(PlanPagePalette.primaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PlanPagePalette.surfaceAlt.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PlanPagePalette.separator)
        )
        .frame(width: 200)
        .position(x: dragState.currentLocation.x, y: dragState.currentLocation.y)
        .allowsHitTesting(false)
        .opacity(0.96)
        .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
    }

    private var isTaskDragActive: Bool {
        switch interactionMode {
        case .draggingTrayTask, .movingBlock:
            return true
        case .idle, .resizingBlock:
            return false
        }
    }

    private var isLaneTargeted: Bool {
        guard case .allDay = currentDropTarget else { return false }
        return true
    }
}

private struct PlannerFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private extension View {
    func plannerFrame(_ id: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: PlannerFramePreferenceKey.self, value: [id: proxy.frame(in: .named("planner"))])
            }
        )
    }
}

private struct PlannerDragState {
    enum Source {
        case task(TaskDTO)
        case block(TimelineBlockDTO)
    }

    let title: String
    let source: Source
    var currentLocation: CGPoint
}

private struct PlanGridPlacementPreview {
    let title: String
    let subtitle: String
    let height: CGFloat
    let offsetY: CGFloat
}

private enum PlanPagePalette {
    static let canvas = dynamic(light: UIColor(red: 0.95, green: 0.93, blue: 0.90, alpha: 1), dark: UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1))
    static let timelineSurface = dynamic(light: UIColor(red: 0.94, green: 0.89, blue: 0.82, alpha: 1), dark: UIColor(red: 0.23, green: 0.19, blue: 0.43, alpha: 1))
    static let rail = dynamic(light: UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1), dark: UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1))
    static let surface = dynamic(light: UIColor(red: 0.95, green: 0.90, blue: 0.84, alpha: 1), dark: UIColor(red: 0.25, green: 0.20, blue: 0.47, alpha: 1))
    static let surfaceAlt = dynamic(light: UIColor(red: 0.92, green: 0.87, blue: 0.82, alpha: 1), dark: UIColor(red: 0.27, green: 0.22, blue: 0.50, alpha: 1))
    static let surfaceOverlay = dynamic(light: UIColor.white.withAlphaComponent(0.16), dark: UIColor.white.withAlphaComponent(0.04))
    static let chipFill = dynamic(light: UIColor.white.withAlphaComponent(0.62), dark: UIColor.black.withAlphaComponent(0.14))
    static let trayFill = dynamic(light: UIColor.white.withAlphaComponent(0.84), dark: UIColor.black.withAlphaComponent(0.24))
    static let buttonFill = dynamic(light: UIColor.white.withAlphaComponent(0.62), dark: UIColor.white.withAlphaComponent(0.08))
    static let selectionFill = SagePalette.brand.opacity(0.18)
    static let separator = dynamic(light: UIColor.black.withAlphaComponent(0.08), dark: UIColor.white.withAlphaComponent(0.10))
    static let shellStroke = dynamic(light: UIColor.black.withAlphaComponent(0.08), dark: UIColor.white.withAlphaComponent(0.10))
    static let primaryText = dynamic(light: UIColor.label, dark: UIColor.white)
    static let secondaryText = dynamic(light: UIColor.secondaryLabel, dark: UIColor.white.withAlphaComponent(0.68))
    static let tertiaryText = dynamic(light: UIColor.tertiaryLabel, dark: UIColor.white.withAlphaComponent(0.42))
    static let railPrimaryText = Color.white
    static let railSecondaryText = Color.white.opacity(0.58)
    static let railMutedText = Color.white.opacity(0.82)

    static func accent(for task: TaskDTO) -> Color {
        switch task.priority {
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

    static func blockFill(for task: TaskDTO, isActive: Bool) -> LinearGradient {
        let accent = accent(for: task)
        return LinearGradient(
            colors: [
                accent.opacity(isActive ? 0.28 : 0.20),
                surfaceAlt.opacity(0.96)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}

private extension TimelineBlockDTO {
    var asTimeBlockDTO: TimeBlockDTO {
        TimeBlockDTO(
            id: id,
            taskId: taskId,
            startAt: startAt,
            endAt: endAt,
            subTaskId: subTaskId,
            isAllDay: isAllDay,
            originTimeBlockId: originTimeBlockId,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

private enum PlanInteractionState: Equatable {
    case idle
    case draggingTrayTask(String)
    case movingBlock(String)
    case resizingBlock(String)

    func matches(blockID: String) -> Bool {
        switch self {
        case let .movingBlock(id), let .resizingBlock(id):
            return id == blockID
        case .idle, .draggingTrayTask:
            return false
        }
    }
}

private enum PlanTransientFeedbackStyle {
    case toast
    case banner
}

private struct PlanTransientFeedbackView: View {
    let message: String
    let style: PlanTransientFeedbackStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style == .toast ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(style == .toast ? PlanPagePalette.primaryText : SagePalette.brand)
            Text(message)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.leading)
                .foregroundStyle(PlanPagePalette.primaryText)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: style == .toast ? 16 : 14, style: .continuous)
                .fill(style == .toast ? Color.black.opacity(0.84) : PlanPagePalette.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style == .toast ? 16 : 14, style: .continuous)
                .strokeBorder(style == .toast ? Color.clear : PlanPagePalette.separator)
        )
    }
}

private struct PlanPlacementPreviewView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PlanPagePalette.primaryText)
                .lineLimit(2)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(PlanPagePalette.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(PlanPagePalette.surfaceAlt.opacity(0.95))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
                .foregroundStyle(SagePalette.brand.opacity(0.7))
        )
    }
}

private enum PlanHaptics {
    @MainActor
    static func selection() {
        #if canImport(UIKit)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    @MainActor
    static func error() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        #endif
    }
}

@MainActor
private struct PlannerTaskChip: View {
    let task: TaskDTO
    let scheduledMinutes: Int
    let language: AppLanguage
    let isExpanded: Bool
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(PlanPagePalette.accent(for: task))
                    .frame(width: 7, height: 7)

                Text(task.title)
                    .font(.system(size: isExpanded ? 14 : 13, weight: .semibold))
                    .foregroundStyle(PlanPagePalette.primaryText)
                    .lineLimit(isExpanded ? 2 : 1)

                Spacer(minLength: 0)

                dragHandle
            }

            HStack(spacing: 8) {
                if let dueAt = task.dueAt {
                    compactMeta(systemName: "calendar", title: formattedDate(dueAt), tint: PlanPagePalette.secondaryText)
                }
                if let estimateMinutes = task.estimateMinutes, isExpanded {
                    compactMeta(
                        systemName: "clock",
                        title: "\(scheduledMinutes)/\(estimateMinutes)m",
                        tint: scheduledMinutes >= estimateMinutes ? .green : PlanPagePalette.secondaryText
                    )
                } else if scheduledMinutes > 0 {
                    compactMeta(systemName: "calendar.badge.clock", title: "\(scheduledMinutes)m", tint: .blue)
                }
            }
        }
        .frame(width: isExpanded ? 186 : 150, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, isExpanded ? 12 : 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PlanPagePalette.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PlanPagePalette.separator)
        )
        .accessibilityHint(Text(localizedAppText(for: language, chinese: "左右滑动可查看更多任务，长按右侧拖拽柄可拖到时间轴或全天区", english: "Swipe horizontally to browse more tasks. Long press the drag handle on the right, then drag onto the grid or all-day lane.")))
    }

    private func formattedDate(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .omitted) ?? string
    }

    @ViewBuilder
    private func compactMeta(systemName: String, title: String, tint: Color) -> some View {
        Label(title, systemImage: systemName)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private var dragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("planner")))
            .onChanged { value in
                if case let .second(true, drag?) = value {
                    onDragChanged(drag.location)
                }
            }
            .onEnded { value in
                if case let .second(true, drag?) = value {
                    onDragEnded(drag.location)
                }
            }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(PlanPagePalette.secondaryText)
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PlanPagePalette.buttonFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(dragGesture)
            .accessibilityElement()
            .accessibilityLabel(Text(localizedAppText(for: language, chinese: "拖拽任务", english: "Drag task")))
    }
}

@MainActor
private struct PlannerTimelineBlockCard: View {
    let block: TimelineBlockDTO
    let baseHeight: CGFloat
    let language: AppLanguage
    let title: String
    let subtitle: String
    let isActive: Bool
    let onTap: () -> Void
    let onMoveChanged: (CGPoint) -> Void
    let onMoveEnded: (CGPoint) -> Void
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: (CGFloat) -> Void

    @State private var resizeTranslation: CGFloat = 0

    var body: some View {
        let accent = PlanPagePalette.accent(for: block.task)
        let previewHeight = max(50, baseHeight + resizeTranslation)

        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(accent)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text(timeRange)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PlanPagePalette.secondaryText)
                        .textCase(.uppercase)
                        .lineLimit(1)

                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(PlanPagePalette.primaryText)
                        .lineLimit(2)

                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(PlanPagePalette.secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .onTapGesture(perform: onTap)
            .simultaneousGesture(moveGesture)

            PlannerResizeHandle(
                translation: $resizeTranslation,
                tint: accent,
                onChanged: onResizeChanged,
                onEnded: onResizeEnded
            )
        }
        .frame(maxWidth: .infinity, minHeight: previewHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(PlanPagePalette.blockFill(for: block.task, isActive: isActive))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(isActive ? accent.opacity(0.95) : PlanPagePalette.separator, lineWidth: isActive ? 1.4 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .accessibilityLabel("\(title), \(timeRange)")
    }

    private var timeRange: String {
        let start = Date.fromISO8601(block.startAt)?.formatted(date: .omitted, time: .shortened) ?? block.startAt
        let end = Date.fromISO8601(block.endAt)?.formatted(date: .omitted, time: .shortened) ?? block.endAt
        return "\(start) - \(end)"
    }

    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("planner")))
            .onChanged { value in
                if case let .second(true, drag?) = value {
                    onMoveChanged(drag.location)
                }
            }
            .onEnded { value in
                if case let .second(true, drag?) = value {
                    onMoveEnded(drag.location)
                }
            }
    }
}

@MainActor
private struct PlannerResizeHandle: View {
    @Binding var translation: CGFloat
    let tint: Color
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.and.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PlanPagePalette.secondaryText)
            Capsule(style: .continuous)
                .fill(tint.opacity(0.9))
                .frame(width: 26, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .contentShape(Rectangle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("planner"))
                .onChanged { value in
                    translation = value.translation.height
                    onChanged(value.translation.height)
                }
                .onEnded { value in
                    translation = 0
                    onEnded(value.translation.height)
                }
        )
    }
}

private struct TimelineDaySection: Identifiable {
    let day: Date
    let assignments: [TimelineBlockDTO]
    let timedBlocks: [TimelineBlockDTO]

    var id: String {
        String(day.timeIntervalSinceReferenceDate)
    }
}

@MainActor
private struct TimelineDayHeader: View {
    let day: Date
    let language: AppLanguage
    let onAddAssignment: () -> Void
    let onAddTimedBlock: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(day.formatted(date: .complete, time: .omitted))
                    .font(.headline.weight(.semibold))
                Text(localizedAppText(for: language, chinese: "待部署区和时间块", english: "Assignments and timed blocks"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button(action: onAddAssignment) {
                    Label(localizedAppText(for: language, chinese: "加入待部署区", english: "Add assignment"), systemImage: "square.stack.badge.plus")
                }
                Button(action: onAddTimedBlock) {
                    Label(localizedAppText(for: language, chinese: "安排时间", english: "Schedule time"), systemImage: "calendar.badge.plus")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct TimelineAssignmentStrip: View {
    let assignments: [TimelineBlockDTO]
    let language: AppLanguage
    let onSelect: (TimelineBlockDTO) -> Void
    let onAddAssignment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(localizedAppText(for: language, chinese: "待部署区", english: "Deployment row"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if assignments.isEmpty {
                        Button(action: onAddAssignment) {
                            Label(localizedAppText(for: language, chinese: "加入待部署区", english: "Add assignment"), systemImage: "plus")
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(assignments) { assignment in
                            Button {
                                onSelect(assignment)
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(assignment.originTimeBlockId == nil ? Color.orange : Color.blue)
                                        .frame(width: 8, height: 8)
                                    Text(timelineAssignmentTitle(for: assignment))
                                        .lineLimit(1)
                                        .font(.footnote.weight(.semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.thinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func timelineAssignmentTitle(for assignment: TimelineBlockDTO) -> String {
        if let subTaskId = assignment.subTaskId,
           let subtask = assignment.task.subtasks.first(where: { $0.id == subTaskId }) {
            return subtask.title
        }

        return assignment.task.title
    }
}

@MainActor
private struct TimelineBlockInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment

    let block: TimelineBlockDTO
    let onChanged: () -> Void

    @State private var currentTask: TaskDTO
    @State private var currentBlock: TimeBlockDTO
    @State private var showingEditor = false
    @State private var placementContext: TimelinePlacementContext?
    @State private var errorMessage: String?

    init(block: TimelineBlockDTO, onChanged: @escaping () -> Void) {
        self.block = block
        self.onChanged = onChanged
        _currentTask = State(initialValue: block.task)
        _currentBlock = State(
            initialValue: TimeBlockDTO(
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
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentTask.title)
                            .font(.title3.weight(.bold))
                        Text(primaryDescription)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section(localizedAppText(for: environment.settings.language, chinese: "部署对象", english: "Deployment target")) {
                    ForEach(deploymentOptions(for: currentTask, language: environment.settings.language)) { option in
                        Button {
                            Task { @MainActor in
                                await updateDeploymentTarget(option)
                            }
                        } label: {
                            HStack {
                                Text(option.title)
                                Spacer()
                                if currentBlock.subTaskId == option.subTaskId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !currentTask.subtasks.isEmpty {
                    Section(localizedAppText(for: environment.settings.language, chinese: "子任务", english: "Subtasks")) {
                        ForEach(currentTask.subtasks.sorted(by: subtaskComesFirst)) { subtask in
                            HStack(spacing: 10) {
                                Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(subtask.done ? .green : .secondary)
                                Text(subtask.title)
                                    .strikethrough(subtask.done)
                            }
                        }
                    }
                }

                if currentBlock.isAllDay {
                    Section {
                        Button {
                            placementContext = TimelinePlacementContext(
                                availableTasks: [currentTask],
                                preselectedTaskID: currentTask.id,
                                preselectedDate: Date.fromISO8601(currentBlock.startAt) ?? .now,
                                preferredMode: .timed,
                                lockedSubTaskId: currentBlock.subTaskId,
                                lockTaskSelection: true,
                                lockDeploymentTargetSelection: true
                            )
                        } label: {
                            Label(localizedAppText(for: environment.settings.language, chinese: "按当前部署对象安排时间", english: "Schedule with this deployment target"), systemImage: "calendar.badge.plus")
                        }

                        if currentBlock.originTimeBlockId != nil {
                            Text(localizedAppText(for: environment.settings.language, chinese: "这是由时间块自动补出的部署项，删除对应时间块后会一起消失。", english: "This assignment was auto-created from a timed block and will disappear with that timed block."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Button(role: .destructive) {
                                Task { @MainActor in
                                    await deleteAssignment()
                                }
                            } label: {
                                Label("common.delete", systemImage: "trash")
                            }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .sageListChrome()
            .navigationTitle(currentBlock.isAllDay ? LocalizedStringKey("timeline.allDay") : LocalizedStringKey("timeline.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") { dismiss() }
                }
                if !currentBlock.isAllDay {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.edit") {
                            showingEditor = true
                        }
                    }
                }
            }
            .task {
                await refreshTask()
            }
            .sheet(isPresented: $showingEditor) {
                TimeBlockEditorSheet(task: currentTask, existing: currentBlock) { saved in
                    currentBlock = saved
                    onChanged()
                    Task { @MainActor in
                        await refreshTask()
                    }
                } onDelete: {
                    onChanged()
                    dismiss()
                }
            }
            .sheet(item: $placementContext) { context in
                TimelinePlacementSheet(context: context) { _ in
                    onChanged()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var primaryDescription: String {
        if currentBlock.isAllDay {
            let date = Date.fromISO8601(currentBlock.startAt)?.formatted(date: .complete, time: .omitted) ?? currentBlock.startAt
            let originLabel = currentBlock.originTimeBlockId == nil
                ? localizedAppText(for: environment.settings.language, chinese: "手动部署", english: "Manual assignment")
                : localizedAppText(for: environment.settings.language, chinese: "自动同步部署", english: "Auto assignment")
            return "\(date) · \(originLabel)"
        }

        let start = Date.fromISO8601(currentBlock.startAt)?.formatted(date: .abbreviated, time: .shortened) ?? currentBlock.startAt
        let end = Date.fromISO8601(currentBlock.endAt)?.formatted(date: .omitted, time: .shortened) ?? currentBlock.endAt
        return "\(start) - \(end)"
    }

    private func refreshTask() async {
        do {
            let refreshed: TaskDTO = try await environment.apiClient.send(path: "/api/mobile/v1/tasks/\(currentTask.id)")
            currentTask = refreshed
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateDeploymentTarget(_ option: DeploymentTargetOption) async {
        guard currentBlock.subTaskId != option.subTaskId else { return }

        do {
            let request = TimeBlockWriteRequest(
                startAt: currentBlock.startAt,
                endAt: currentBlock.endAt,
                subTaskId: option.subTaskId,
                isAllDay: currentBlock.isAllDay
            )
            let saved: TimeBlockDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(currentBlock.id)",
                method: "PATCH",
                body: request
            )
            currentBlock = saved
            errorMessage = nil
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAssignment() async {
        do {
            let _: EmptySuccessDTO = try await environment.apiClient.send(
                path: "/api/mobile/v1/time-blocks/\(currentBlock.id)",
                method: "DELETE",
                body: EmptyBody()
            )
            onChanged()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func subtaskComesFirst(_ lhs: SubTaskDTO, _ rhs: SubTaskDTO) -> Bool {
        if lhs.sortOrder != rhs.sortOrder {
            return lhs.sortOrder < rhs.sortOrder
        }
        return lhs.createdAt < rhs.createdAt
    }
}
