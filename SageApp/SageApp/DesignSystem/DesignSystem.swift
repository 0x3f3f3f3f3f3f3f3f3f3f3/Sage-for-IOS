import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum SageCornerRadius {
    static let compact: CGFloat = 14
    static let regular: CGFloat = 16
    static let prominent: CGFloat = 20
}

struct GlassToolbarButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}

struct GlassPrimaryButton: View {
    let title: LocalizedStringKey
    let systemName: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemName {
                    Image(systemName: systemName)
                }
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color.orange, Color.orange.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous)
        )
    }
}

struct GlassSegmentedFilterRow<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> LocalizedStringKey
    @Binding var selection: Item

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    Button {
                        selection = item
                    } label: {
                        Text(title(item))
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(selection == item ? .white : .primary)
                            .background(
                                Group {
                                    if selection == item {
                                        Capsule()
                                            .fill(Color.orange)
                                    } else {
                                        Capsule()
                                            .fill(.thinMaterial)
                                    }
                                }
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct TagChipView: View {
    let tag: TagDTO

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: tag.color))
                .frame(width: 8, height: 8)
            Text(tag.name)
                .lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }
}

struct FloatingComposerBar<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.prominent, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 16, y: 12)
    }
}

struct EmptyStateView: View {
    let systemName: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemName)
        } description: {
            Text(message)
        }
    }
}

struct ErrorStateView: View {
    let message: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let retry {
                GlassPrimaryButton(title: "common.retry", systemName: "arrow.clockwise", action: retry)
            }
        }
        .padding()
    }
}

struct LoadingStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("common.loading")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MarkdownPreviewView: View {
    let markdown: String

    var body: some View {
        let processed = markdown
            .replacingOccurrences(of: "- [ ]", with: "☐")
            .replacingOccurrences(of: "- [x]", with: "☑")
            .replacingOccurrences(of: "- [X]", with: "☑")

        if let attributed = try? AttributedString(markdown: processed) {
            Text(attributed)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(processed)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let content: Content

    init(title: LocalizedStringKey, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            content
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous))
    }
}

struct SectionHeaderView: View {
    let title: LocalizedStringKey
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SageListChromeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}

extension View {
    func sageListChrome() -> some View {
        modifier(SageListChromeModifier())
    }

    func sageListRowChrome() -> some View {
        listRowBackground(Color.clear)
    }
}

@MainActor
func dismissKeyboard() {
#if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
#endif
}

func makeAPIPath(_ basePath: String, queryItems: [URLQueryItem]) -> String {
    var components = URLComponents()
    components.queryItems = queryItems.isEmpty ? nil : queryItems
    guard var percentEncodedQuery = components.percentEncodedQuery, !percentEncodedQuery.isEmpty else {
        return basePath
    }
    percentEncodedQuery = percentEncodedQuery.replacingOccurrences(of: "+", with: "%2B")
    return "\(basePath)?\(percentEncodedQuery)"
}

extension Color {
    init(hex: String) {
        let sanitized = hex.replacingOccurrences(of: "#", with: "")
        let value = UInt64(sanitized, radix: 16) ?? 0xC96444
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String {
#if canImport(UIKit)
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#C96444"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(round(red * 255)),
            Int(round(green * 255)),
            Int(round(blue * 255))
        )
#else
        return "#C96444"
#endif
    }
}

extension Date {
    private static func makeISO8601FormatterWithFraction() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func makeISO8601FormatterWithoutFraction() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    static func fromISO8601(_ string: String?) -> Date? {
        guard let string else { return nil }
        return Date.makeISO8601FormatterWithFraction().date(from: string)
            ?? Date.makeISO8601FormatterWithoutFraction().date(from: string)
    }
}
