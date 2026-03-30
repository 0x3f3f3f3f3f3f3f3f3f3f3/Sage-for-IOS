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
        Form {
            if let currentUser = environment.authStore.currentUser {
                Section(localizedAppText(for: settings.language, chinese: "账户", english: "Account")) {
                    LabeledContent(
                        localizedAppText(for: settings.language, chinese: "用户名", english: "Username"),
                        value: currentUser.username
                    )

                    if let session = environment.authStore.session {
                        LabeledContent(
                            localizedAppText(for: settings.language, chinese: "设备", english: "Device"),
                            value: session.deviceName ?? UIDevice.current.model
                        )
                        LabeledContent(
                            localizedAppText(for: settings.language, chinese: "会话到期", english: "Session expires"),
                            value: formattedDateTime(session.expiresAt)
                        )
                    }
                }
            }

            Section(localizedAppText(for: settings.language, chinese: "外观", english: "Appearance")) {
                Picker("settings.theme", selection: Binding(get: { environment.settings.theme }, set: { updateTheme($0) })) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(LocalizedStringKey(theme.localizationKey)).tag(theme)
                    }
                }
            }

            Section(localizedAppText(for: settings.language, chinese: "语言", english: "Language")) {
                Picker("settings.language", selection: Binding(get: { environment.settings.language }, set: { updateLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.localizationKey)).tag(language)
                    }
                }
            }

            Section(localizedAppText(for: settings.language, chinese: "时区", english: "Timezone")) {
                Picker("settings.timezone", selection: Binding(get: { environment.settings.timezoneMode }, set: { updateTimezoneMode($0) })) {
                    ForEach(TimezoneMode.allCases) { mode in
                        Text(LocalizedStringKey(mode.localizationKey)).tag(mode)
                    }
                }

                if environment.settings.timezoneMode == .manual {
                    Picker(
                        localizedAppText(for: settings.language, chinese: "时区", english: "Timezone"),
                        selection: Binding(get: { environment.settings.timezoneOverride ?? "UTC" }, set: { updateTimezoneOverride($0) })
                    ) {
                        ForEach(commonTimezones, id: \.self) { timezone in
                            Text(timezone).tag(timezone)
                        }
                    }
                } else {
                    LabeledContent(
                        localizedAppText(for: settings.language, chinese: "当前", english: "Current"),
                        value: environment.settings.effectiveTimeZoneIdentifier
                    )
                }
            }

            Section(localizedAppText(for: settings.language, chinese: "后端", english: "Backend")) {
                TextField(AppSettingsStore.defaultServerBaseURL, text: $backendURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        environment.settings.setServerBaseURL(backendURL)
                    }

                Text(backendURLHelpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(localizedAppText(for: settings.language, chinese: "提醒", english: "Notifications")) {
                Text(localizedAppText(
                    for: settings.language,
                    chinese: "任务提醒会使用当前语言、时区和系统通知设置。",
                    english: "Task reminders use the current language, timezone, and system notification settings."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    Task { @MainActor in
                        await environment.authStore.logout()
                    }
                } label: {
                    Label("settings.logout", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle(localizedAppText(for: settings.language, chinese: "设置", english: "Settings"))
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

    private func formattedDateTime(_ string: String) -> String {
        Date.fromISO8601(string)?.formatted(date: .abbreviated, time: .shortened) ?? string
    }
}

private struct SettingsPatchRequest: Encodable {
    let language: AppLanguage?
    let theme: AppTheme?
    let timezoneMode: TimezoneMode?
    let timezoneOverride: String?
}
