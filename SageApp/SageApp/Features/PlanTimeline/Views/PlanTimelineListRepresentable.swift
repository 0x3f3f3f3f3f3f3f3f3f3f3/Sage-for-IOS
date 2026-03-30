import SwiftUI
import UIKit

private final class PlanHostingCell: UITableViewCell {
    static let identifier = "PlanHostingCell"

    private var hostingController: UIHostingController<AnyView>?

    func configure(with view: AnyView) {
        if let hostingController {
            hostingController.rootView = view
        } else {
            let controller = UIHostingController(rootView: view)
            controller.view.backgroundColor = .clear
            hostingController = controller

            let rootView = controller.view!
            rootView.translatesAutoresizingMaskIntoConstraints = false
            rootView.backgroundColor = .clear
            contentView.backgroundColor = .clear
            backgroundColor = .clear

            contentView.addSubview(rootView)

            NSLayoutConstraint.activate([
                rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
                rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }

        layoutIfNeeded()
    }
}

struct PlanTimelineListRepresentable: UIViewRepresentable {
    let sections: [PlanDaySection]
    let selectedDate: Date
    let language: AppLanguage
    let listScrollState: PlanListScrollState
    let onTapItem: (PlanTimelineItem) -> Void
    let onTapEmptyDate: (Date) -> Void

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView()
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 136
        tableView.contentInset = UIEdgeInsets(top: 8, left: 0, bottom: 120, right: 0)
        tableView.register(PlanHostingCell.self, forCellReuseIdentifier: PlanHostingCell.identifier)
        tableView.dataSource = context.coordinator
        listScrollState.attach(to: tableView)
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.parent = self
        listScrollState.configure(with: sections.map(\.date), selectedDate: selectedDate)
        tableView.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITableViewDataSource {
        var parent: PlanTimelineListRepresentable

        init(parent: PlanTimelineListRepresentable) {
            self.parent = parent
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            parent.sections.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: PlanHostingCell.identifier, for: indexPath) as! PlanHostingCell
            let section = parent.sections[indexPath.row]
            let rootView = PlanTimelineDayRow(
                section: section,
                language: parent.language,
                isSelected: Calendar.current.isDate(section.date, inSameDayAs: parent.selectedDate),
                isFilled: indexPath.row.isMultiple(of: 2),
                onTapItem: parent.onTapItem,
                onTapEmptyDate: parent.onTapEmptyDate
            )
            .id(section.id)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color.clear)
            .eraseToAnyView()

            cell.configure(with: rootView)
            cell.selectionStyle = .none
            return cell
        }
    }
}

private struct PlanTimelineDayRow: View {
    let section: PlanDaySection
    let language: AppLanguage
    let isSelected: Bool
    let isFilled: Bool
    let onTapItem: (PlanTimelineItem) -> Void
    let onTapEmptyDate: (Date) -> Void

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                Text(section.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? SagePalette.brand : .secondary)
                Text(section.date.formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 42)
            .padding(.trailing, 8)

            VStack(alignment: .leading, spacing: 10) {
                if section.items.isEmpty {
                    Button {
                        onTapEmptyDate(section.date)
                    } label: {
                        HStack {
                            Label(
                                localizedAppText(for: language, chinese: "暂无安排", english: "No scheduled items"),
                                systemImage: "calendar.badge.plus"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(section.items) { item in
                        Button {
                            onTapItem(item)
                        } label: {
                            PlanTimelineItemCell(item: item, language: language)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(isFilled ? SagePalette.surface : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(isSelected ? SagePalette.brand.opacity(0.35) : SagePalette.separator)
            )
        }
    }
}

private extension View {
    func eraseToAnyView() -> AnyView {
        AnyView(self)
    }
}
