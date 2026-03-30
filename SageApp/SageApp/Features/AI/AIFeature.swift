import SwiftUI
import Observation

struct ChatMessage: Identifiable, Hashable, Encodable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    let content: String

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

@MainActor
@Observable
final class AIChatViewModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isStreaming = false
    var errorMessage: String?

    func send(using api: APIClient, locale: AppLanguage, timezone: String) async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        input = ""
        errorMessage = nil
        isStreaming = true
        defer { isStreaming = false }

        let history = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let userMessage = ChatMessage(role: .user, content: prompt)
        let assistantPlaceholder = ChatMessage(role: .assistant, content: "")
        messages = history + [userMessage, assistantPlaceholder]

        let request = AIChatRequest(
            messages: (history + [userMessage]).map { AIMessageRequest(role: $0.role, content: $0.content) },
            locale: locale,
            timezone: timezone
        )

        do {
            var content = ""
            for try await line in api.streamText(path: "/api/mobile/v1/ai/chat", body: request) {
                content += line
                if let index = messages.lastIndex(where: { $0.role == .assistant }) {
                    messages[index] = ChatMessage(id: messages[index].id, role: .assistant, content: content)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            if let index = messages.lastIndex(where: { $0.role == .assistant && $0.content.isEmpty }) {
                messages.remove(at: index)
            }
        }
    }
}

@MainActor
struct AIAssistantView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var viewModel = AIChatViewModel()
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if viewModel.messages.isEmpty {
                    EmptyStateView(systemName: "sparkles", title: "ai.empty.title", message: "ai.empty.message")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.messages) { message in
                        HStack {
                            if message.role == .assistant {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Sage")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                    MarkdownPreviewView(markdown: message.content)
                                }
                                Spacer()
                            } else {
                                Spacer()
                                Text(message.content)
                                    .padding(12)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous))
                            }
                        }
                        .sageListRowChrome()
                        .id(message.id)
                    }
                }
            }
            .sageListChrome()
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(
                TapGesture().onEnded {
                    inputFocused = false
                    dismissKeyboard()
                }
            )
            .safeAreaInset(edge: .bottom) {
                FloatingComposerBar {
                    VStack(alignment: .leading, spacing: 8) {
                        if let errorMessage = viewModel.errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                        HStack(alignment: .center, spacing: 12) {
                            TextField("ai.placeholder", text: $viewModel.input, axis: .vertical)
                                .lineLimit(1...6)
                                .padding(.vertical, SageComposerMetrics.fieldVerticalPadding)
                                .frame(minHeight: SageComposerMetrics.fieldMinHeight, alignment: .center)
                                .focused($inputFocused)
                            Button {
                                inputFocused = false
                                dismissKeyboard()
                                Task { @MainActor in
                                    await viewModel.send(using: environment.apiClient, locale: environment.settings.language, timezone: environment.settings.effectiveTimeZoneIdentifier)
                                }
                            } label: {
                                Image(systemName: viewModel.isStreaming ? "hourglass" : "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.orange)
                            }
                            .disabled(viewModel.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .navigationTitle(localizedAppText(for: settings.language, chinese: "AI 助手", english: "AI"))
            .onChange(of: viewModel.messages) { _, messages in
                if let lastID = messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct AIChatRequest: Encodable {
    let messages: [AIMessageRequest]
    let locale: AppLanguage
    let timezone: String
}

private struct AIMessageRequest: Encodable {
    let role: ChatMessage.Role
    let content: String
}
