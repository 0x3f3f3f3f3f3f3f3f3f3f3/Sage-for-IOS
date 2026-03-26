import SwiftUI
import Observation

@MainActor
@Observable
final class InboxViewModel {
    var items: [InboxItemDTO] = []
    var isLoading = false
    var errorMessage: String?
    var composerText = ""

    func load(using api: APIClient) async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await api.send(path: "/api/mobile/v1/inbox")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addCapture(using api: APIClient) async {
        let content = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        do {
            let created: InboxItemDTO = try await api.send(
                path: "/api/mobile/v1/inbox",
                method: "POST",
                body: InboxCaptureRequest(content: content)
            )
            items.insert(created, at: 0)
            composerText = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(id: String, using api: APIClient) async {
        do {
            let _: EmptySuccessDTO = try await api.send(path: "/api/mobile/v1/inbox/\(id)", method: "DELETE", body: EmptyBody())
            items.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func process(id: String, processType: InboxProcessType, title: String?, using api: APIClient) async {
        do {
            let _: InboxProcessResponseDTO = try await api.send(
                path: "/api/mobile/v1/inbox/\(id)/process",
                method: "POST",
                body: InboxProcessRequest(processType: processType, title: title)
            )
            items.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
struct InboxView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = InboxViewModel()
    @State private var processingItem: InboxItemDTO?
    @State private var processingTitle = ""
    @State private var processingType: InboxProcessType = .task
    @FocusState private var composerFocused: Bool

    var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage, retry: {
                    Task { @MainActor in
                        await viewModel.load(using: environment.apiClient)
                    }
                })
                .listRowBackground(Color.clear)
            } else if viewModel.isLoading {
                LoadingStateView()
                    .listRowBackground(Color.clear)
            } else if viewModel.items.isEmpty {
                EmptyStateView(systemName: "tray", title: "inbox.empty.title", message: "inbox.empty.message")
                    .listRowBackground(Color.clear)
            } else {
                ForEach(viewModel.items) { item in
                    Button {
                        openProcessing(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.content)
                                .font(.body)
                            Text(relativeTimestamp(item.capturedAt))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .padding(.vertical, 8)
                    .sageListRowChrome()
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            Task { @MainActor in
                                await viewModel.delete(id: item.id, using: environment.apiClient)
                            }
                        } label: {
                            Label("common.delete", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            openProcessing(item, processType: .task)
                        } label: {
                            Label("inbox.toTask", systemImage: "checklist")
                        }

                        Button {
                            openProcessing(item, processType: .note)
                        } label: {
                            Label("inbox.toNote", systemImage: "note.text")
                        }

                        Button {
                            openProcessing(item, processType: .both)
                        } label: {
                            Label("inbox.toBoth", systemImage: "square.stack.3d.up")
                        }
                    }
                }
            }
        }
        .sageListChrome()
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(
            TapGesture().onEnded {
                composerFocused = false
                dismissKeyboard()
            }
        )
        .safeAreaInset(edge: .bottom) {
            FloatingComposerBar {
                HStack(spacing: 12) {
                    TextField("inbox.capture.placeholder", text: $viewModel.composerText, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                    Button {
                        composerFocused = false
                        dismissKeyboard()
                        Task { @MainActor in
                            await viewModel.addCapture(using: environment.apiClient)
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                    }
                    .disabled(viewModel.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(.clear)
        }
        .navigationTitle(localizedAppText(for: settings.language, chinese: "收件箱", english: "Inbox"))
        .task {
            await viewModel.load(using: environment.apiClient)
        }
        .sheet(item: $processingItem) { item in
            NavigationStack {
                Form {
                    Picker("inbox.process.type", selection: $processingType) {
                        Text("inbox.toTask").tag(InboxProcessType.task)
                        Text("inbox.toNote").tag(InboxProcessType.note)
                        Text("inbox.toBoth").tag(InboxProcessType.both)
                    }

                    TextField("inbox.process.title", text: $processingTitle)
                }
                .navigationTitle(Text("inbox.process"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("common.cancel") { processingItem = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.save") {
                            Task { @MainActor in
                                await viewModel.process(id: item.id, processType: processingType, title: processingTitle, using: environment.apiClient)
                                processingItem = nil
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .refreshable {
            await viewModel.load(using: environment.apiClient)
        }
    }

    private func relativeTimestamp(_ string: String) -> String {
        guard let date = Date.fromISO8601(string) else { return string }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    private func openProcessing(_ item: InboxItemDTO, processType: InboxProcessType = .task) {
        composerFocused = false
        dismissKeyboard()
        processingItem = item
        processingTitle = item.content.components(separatedBy: "\n").first ?? item.content
        processingType = processType
    }
}

private struct InboxCaptureRequest: Encodable {
    let content: String
}

private struct InboxProcessRequest: Encodable {
    let processType: InboxProcessType
    let title: String?
}
