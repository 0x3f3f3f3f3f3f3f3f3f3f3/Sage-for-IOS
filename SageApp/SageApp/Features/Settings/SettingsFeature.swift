import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSettingsStore.self) private var settings
    @State private var backendURL = ""

    private let commonTimezones = [
        "UTC",
        "America/Los_Angeles",
        "America/Denver",
        "America/Chicago",
        "America/New_York",
        "Europe/London",
        "Europe/Paris",
        "Asia/Shanghai",
        "Asia/Tokyo",
        "Australia/Sydney"
    ]

    var body: some View {
        List {
            Section {
                SettingsRow(title: "settings.theme", subtitle: nil) {
                    Picker("", selection: Binding(get: { environment.settings.theme }, set: { updateTheme($0) })) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(LocalizedStringKey(theme.localizationKey)).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                .sageListRowChrome()

                SettingsRow(title: "settings.language", subtitle: nil) {
                    Picker("", selection: Binding(get: { environment.settings.language }, set: { updateLanguage($0) })) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.localizationKey)).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                .sageListRowChrome()

                SettingsRow(title: "settings.timezone", subtitle: environment.settings.effectiveTimeZoneIdentifier) {
                    VStack(alignment: .trailing) {
                        Picker("", selection: Binding(get: { environment.settings.timezoneMode }, set: { updateTimezoneMode($0) })) {
                            ForEach(TimezoneMode.allCases) { mode in
                                Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 240)

                        if environment.settings.timezoneMode == .manual {
                            Picker("", selection: Binding(get: { environment.settings.timezoneOverride ?? "UTC" }, set: { updateTimezoneOverride($0) })) {
                                ForEach(commonTimezones, id: \.self) { timezone in
                                    Text(timezone).tag(timezone)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                }
                .sageListRowChrome()
            }

            Section {
                SettingsRow(title: "settings.backendURL", subtitle: backendURLHelpText) {
                    TextField(AppSettingsStore.defaultServerBaseURL, text: $backendURL)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            environment.settings.setServerBaseURL(backendURL)
                        }
                }
                .sageListRowChrome()
            }

            Section {
                Button(role: .destructive) {
                    Task { @MainActor in
                        await environment.authStore.logout()
                    }
                } label: {
                    Label("settings.logout", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .sageListRowChrome()
            }
        }
        .sageListChrome()
        .navigationTitle(localizedAppText(for: settings.language, chinese: "设置", english: "Settings"))
        .preferredColorScheme(environment.settings.sheetPreferredColorScheme)
        .id("settings-\(environment.settings.theme.rawValue)-\(environment.settings.sheetPreferredColorScheme == .dark ? "dark" : "light")")
        .task {
            backendURL = environment.settings.serverBaseURL
        }
    }

    private func updateTheme(_ theme: AppTheme) {
        environment.settings.setTheme(theme)
        Task { @MainActor in
            let _: UserSettingsDTO? = try? await environment.apiClient.send(
                path: "/api/mobile/v1/settings",
                method: "PATCH",
                body: SettingsPatchRequest(
                    language: nil,
                    theme: theme,
                    timezoneMode: nil,
                    timezoneOverride: nil
                )
            )
        }
    }

    private func updateLanguage(_ language: AppLanguage) {
        environment.settings.setLanguage(language)
        Task { @MainActor in
            let _: UserSettingsDTO? = try? await environment.apiClient.send(
                path: "/api/mobile/v1/settings",
                method: "PATCH",
                body: SettingsPatchRequest(
                    language: language,
                    theme: nil,
                    timezoneMode: nil,
                    timezoneOverride: nil
                )
            )
        }
    }

    private func updateTimezoneMode(_ mode: TimezoneMode) {
        environment.settings.setTimezoneMode(mode)
        Task { @MainActor in
            let _: UserSettingsDTO? = try? await environment.apiClient.send(
                path: "/api/mobile/v1/settings",
                method: "PATCH",
                body: SettingsPatchRequest(
                    language: nil,
                    theme: nil,
                    timezoneMode: mode,
                    timezoneOverride: environment.settings.timezoneOverride
                )
            )
        }
    }

    private func updateTimezoneOverride(_ timezone: String) {
        environment.settings.setTimezoneOverride(timezone)
        Task { @MainActor in
            let _: UserSettingsDTO? = try? await environment.apiClient.send(
                path: "/api/mobile/v1/settings",
                method: "PATCH",
                body: SettingsPatchRequest(
                    language: nil,
                    theme: nil,
                    timezoneMode: .manual,
                    timezoneOverride: timezone
                )
            )
        }
    }

    private var backendURLHelpText: String {
        environment.settings.language == .chineseSimplified
            ? "后端地址应为 http://154.83.158.137:3003。"
            : "Use http://154.83.158.137:3003 as the backend URL."
    }
}

private struct SettingsPatchRequest: Encodable {
    let language: AppLanguage?
    let theme: AppTheme?
    let timezoneMode: TimezoneMode?
    let timezoneOverride: String?
}
