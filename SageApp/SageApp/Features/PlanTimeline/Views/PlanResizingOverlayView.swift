import SwiftUI

struct PlanResizingOverlayView: View {
    @ObservedObject var pageState: PlanPageScrollState

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(SagePalette.separator)
            .padding(edgeInset)
            .allowsHitTesting(false)
            .animation(.spring(response: 0.32, dampingFraction: 0.88), value: pageState.activePage)
    }

    private var cornerRadius: CGFloat {
        switch pageState.activePage {
        case .list:
            return 24
        case .monthlyCalendar:
            return 20
        case .yearlyCalendar:
            return 18
        }
    }

    private var edgeInset: CGFloat {
        switch pageState.activePage {
        case .list:
            return 0
        case .monthlyCalendar:
            return 6
        case .yearlyCalendar:
            return 10
        }
    }
}
