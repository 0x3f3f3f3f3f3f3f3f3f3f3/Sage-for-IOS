import Foundation
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Observable
final class AppSettingsStore {
    static let defaultServerBaseURL = "http://154.83.158.137:3003"

    private enum Keys {
        static let language = "sage.language"
        static let theme = "sage.theme"
        static let timezoneMode = "sage.timezoneMode"
        static let timezoneOverride = "sage.timezoneOverride"
        static let serverBaseURL = "sage.serverBaseURL"
    }

    var language: AppLanguage
    var theme: AppTheme
    var timezoneMode: TimezoneMode
    var timezoneOverride: String?
    var serverBaseURL: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .chineseSimplified
        theme = AppTheme(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        timezoneMode = TimezoneMode(rawValue: defaults.string(forKey: Keys.timezoneMode) ?? "") ?? .system
        timezoneOverride = defaults.string(forKey: Keys.timezoneOverride)
        let persistedBaseURL = defaults.string(forKey: Keys.serverBaseURL)
        let resolvedBaseURL = Self.resolveServerBaseURL(from: persistedBaseURL)
        defaults.set(resolvedBaseURL, forKey: Keys.serverBaseURL)
        serverBaseURL = resolvedBaseURL
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    var effectiveTimeZoneIdentifier: String {
        if timezoneMode == .manual, let timezoneOverride, !timezoneOverride.isEmpty {
            return timezoneOverride
        }
        return TimeZone.current.identifier
    }

    var colorSchemeOverride: ColorScheme? {
        switch theme {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            return nil
        }
    }

    var systemColorScheme: ColorScheme {
#if canImport(UIKit)
        let style =
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .sorted { lhs, rhs in
                    lhs.activationState.sortPriority < rhs.activationState.sortPriority
                }
                .first?.screen.traitCollection.userInterfaceStyle

        switch style {
        case .dark:
            return .dark
        default:
            return .light
        }
#else
        return .light
#endif
    }

    var sheetPreferredColorScheme: ColorScheme {
        colorSchemeOverride ?? systemColorScheme
    }

    var locale: Locale {
        Locale(identifier: language.rawValue)
    }

    var normalizedServerBaseURL: String {
        Self.normalizeServerBaseURL(serverBaseURL)
    }

    func setLanguage(_ value: AppLanguage) {
        language = value
        defaults.set(value.rawValue, forKey: Keys.language)
    }

    func setTheme(_ value: AppTheme) {
        theme = value
        defaults.set(value.rawValue, forKey: Keys.theme)
    }

    func setTimezoneMode(_ value: TimezoneMode) {
        timezoneMode = value
        defaults.set(value.rawValue, forKey: Keys.timezoneMode)
    }

    func setTimezoneOverride(_ value: String?) {
        timezoneOverride = value
        defaults.set(value, forKey: Keys.timezoneOverride)
    }

    func setServerBaseURL(_ value: String) {
        let normalizedValue = Self.normalizeServerBaseURL(value)
        serverBaseURL = normalizedValue
        defaults.set(normalizedValue, forKey: Keys.serverBaseURL)
    }

    func applyRemoteSettings(_ settings: UserSettingsDTO) {
        setLanguage(settings.language)
        setTheme(settings.theme)
        setTimezoneMode(settings.timezoneMode)
        setTimezoneOverride(settings.timezoneOverride)
    }

    private static func resolveServerBaseURL(from persistedBaseURL: String?) -> String {
        guard let persistedBaseURL else {
            return defaultServerBaseURL
        }

        let normalizedBaseURL = normalizeServerBaseURL(persistedBaseURL)
        guard !normalizedBaseURL.isEmpty else {
            return defaultServerBaseURL
        }

        if normalizedBaseURL == "http://localhost:3000" || normalizedBaseURL == "http://localhost:3003" {
            return defaultServerBaseURL
        }

        if normalizedBaseURL == "http://127.0.0.1:3000" || normalizedBaseURL == "http://127.0.0.1:3003" {
            return defaultServerBaseURL
        }

        return normalizedBaseURL
    }

    private static func normalizeServerBaseURL(_ value: String) -> String {
        let withoutWhitespace = value.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        guard !withoutWhitespace.isEmpty else {
            return defaultServerBaseURL
        }

        let withScheme = withoutWhitespace.contains("://") ? withoutWhitespace : "http://\(withoutWhitespace)"
        if withScheme.hasSuffix("/") {
            return String(withScheme.dropLast())
        }
        return withScheme
    }
}

#if canImport(UIKit)
private extension UIScene.ActivationState {
    var sortPriority: Int {
        switch self {
        case .foregroundActive:
            return 0
        case .foregroundInactive:
            return 1
        case .background:
            return 2
        case .unattached:
            return 3
        @unknown default:
            return 4
        }
    }
}
#endif
