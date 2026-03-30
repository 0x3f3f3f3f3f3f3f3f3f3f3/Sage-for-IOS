import SwiftUI

@MainActor
final class PlanPageScrollState: ObservableObject {
    @Published var activePage: PlanTimelinePage = .list
    @Published var translation: CGFloat = 0
    @Published var canDrag = true

    var pageWidth: CGFloat = 390

    func updatePageWidth(_ width: CGFloat) {
        pageWidth = max(width, 1)
    }

    func scroll(to page: PlanTimelinePage) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            activePage = page
            translation = 0
        }
    }

    func horizontalDragChanged(_ value: DragGesture.Value) {
        guard canDrag else { return }
        let horizontalTranslation = value.translation.width
        guard abs(horizontalTranslation) > abs(value.translation.height) else {
            translation = 0
            return
        }
        translation = horizontalTranslation
    }

    func horizontalDragEnded(_ value: DragGesture.Value) {
        guard canDrag else {
            translation = 0
            return
        }

        let predicted = value.predictedEndTranslation.width
        let threshold = pageWidth * 0.22
        var targetPage = activePage

        if predicted > threshold {
            targetPage = previousPage(of: activePage)
        } else if predicted < -threshold {
            targetPage = nextPage(of: activePage)
        }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            activePage = targetPage
            translation = 0
        }
    }

    private func previousPage(of page: PlanTimelinePage) -> PlanTimelinePage {
        switch page {
        case .yearlyCalendar:
            return .yearlyCalendar
        case .monthlyCalendar:
            return .yearlyCalendar
        case .list:
            return .monthlyCalendar
        }
    }

    private func nextPage(of page: PlanTimelinePage) -> PlanTimelinePage {
        switch page {
        case .yearlyCalendar:
            return .monthlyCalendar
        case .monthlyCalendar:
            return .list
        case .list:
            return .list
        }
    }
}
