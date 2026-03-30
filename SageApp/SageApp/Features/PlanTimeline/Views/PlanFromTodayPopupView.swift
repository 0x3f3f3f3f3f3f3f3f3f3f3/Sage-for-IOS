import SwiftUI

struct PlanFromTodayPopupView: View {
    @ObservedObject var listScrollState: PlanListScrollState
    let language: AppLanguage

    var body: some View {
        if !Calendar.current.isDateInToday(listScrollState.currentDate) {
            VStack(spacing: 2) {
                Text(distanceTitle)
                    .font(.headline.weight(.semibold))
                Text(localizedAppText(for: language, chinese: "之前", english: "ago"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(SagePalette.separator)
            )
            .scaleEffect(listScrollState.showFromTodayPopup ? 1 : 0.85)
            .opacity(listScrollState.showFromTodayPopup ? 1 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: listScrollState.showFromTodayPopup)
        }
    }

    private var distanceTitle: String {
        let today = Calendar.current.startOfDay(for: .now)
        let current = Calendar.current.startOfDay(for: listScrollState.currentDate)
        let days = abs(Calendar.current.dateComponents([.day], from: current, to: today).day ?? 0)
        if days < 14 {
            return localizedAppText(for: language, chinese: "\(max(days / 7, 1)) 周", english: "\(max(days / 7, 1)) week")
        }
        if days < 60 {
            return localizedAppText(for: language, chinese: "\(max(days / 7, 1)) 周", english: "\(max(days / 7, 1)) weeks")
        }
        return localizedAppText(for: language, chinese: "\(max(days / 30, 1)) 月", english: "\(max(days / 30, 1)) months")
    }
}
