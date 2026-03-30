import SwiftUI

struct PlanMonthYearSideBar: View {
    let currentDate: Date
    let language: AppLanguage
    let onPreviousMonth: () -> Void
    let onNextMonth: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onPreviousMonth) {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Text(currentDate.formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(-90))
                Text(currentDate.formatted(.dateTime.year()))
                    .font(.caption2.weight(.medium))
                    .rotationEffect(.degrees(-90))
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(action: onNextMonth) {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .frame(width: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }
}
