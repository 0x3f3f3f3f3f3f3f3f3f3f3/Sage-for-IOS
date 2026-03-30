import Foundation
import UIKit

@MainActor
final class PlanListScrollState: NSObject, ObservableObject {
    @Published var currentDate: Date = Calendar.current.startOfDay(for: .now)
    @Published var showFromTodayPopup = false

    var orderedDates: [Date] = []
    var onVisibleDateChanged: ((Date) -> Void)?

    weak var tableView: UITableView?

    func configure(with dates: [Date], selectedDate: Date) {
        orderedDates = dates
        currentDate = Calendar.current.startOfDay(for: selectedDate)
    }

    func attach(to tableView: UITableView) {
        self.tableView = tableView
        tableView.delegate = self
    }

    func scroll(to date: Date, animated: Bool = true) {
        guard let tableView,
              let row = orderedDates.firstIndex(where: {
                  Calendar.current.isDate($0, inSameDayAs: date)
              }) else {
            return
        }

        let indexPath = IndexPath(row: row, section: 0)
        tableView.scrollToRow(at: indexPath, at: .top, animated: animated)
        updateVisibleDate(to: orderedDates[row], notify: true)
    }

    func scrollToToday() {
        scroll(to: .now, animated: true)
    }

    private func updateVisibleDate(to date: Date, notify: Bool) {
        let normalized = Calendar.current.startOfDay(for: date)
        guard !Calendar.current.isDate(normalized, inSameDayAs: currentDate) else { return }
        currentDate = normalized
        if notify {
            onVisibleDateChanged?(normalized)
        }
    }
}

extension PlanListScrollState: UITableViewDelegate {
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        showFromTodayPopup = true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let tableView,
              let firstVisible = tableView.indexPathsForVisibleRows?.min() else {
            return
        }
        updateVisibleDate(to: orderedDates[firstVisible.row], notify: true)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        showFromTodayPopup = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            showFromTodayPopup = false
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        showFromTodayPopup = false
    }
}
