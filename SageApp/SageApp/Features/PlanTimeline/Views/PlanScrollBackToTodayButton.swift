import SwiftUI

struct PlanScrollBackToTodayButton: View {
    @ObservedObject var listScrollState: PlanListScrollState
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.headline.weight(.bold))
                .foregroundStyle(SagePalette.brand)
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                )
                .overlay(
                    Circle()
                        .strokeBorder(SagePalette.separator)
                )
                .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .scaleEffect(Calendar.current.isDateInToday(listScrollState.currentDate) ? 0.8 : 1)
        .opacity(Calendar.current.isDateInToday(listScrollState.currentDate) ? 0 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: listScrollState.currentDate)
        .accessibilityLabel(Text(localizedAppText(for: language, chinese: "回到今天", english: "Back to today")))
    }
}
