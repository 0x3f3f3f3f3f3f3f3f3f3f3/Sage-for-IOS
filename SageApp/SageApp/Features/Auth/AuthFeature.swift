import SwiftUI

@MainActor
struct AuthSceneView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var mode: AuthMode = .login
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [.orange.opacity(0.20), .yellow.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(spacing: 12) {
                            Image(systemName: "leaf.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.orange.gradient)
                            Text("Sage")
                                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            Text(mode.subtitleKey)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        GlassSegmentedFilterRow(items: AuthMode.allCases, title: \.title, selection: $mode)

                        VStack(spacing: 16) {
                            TextField("auth.username", text: $username)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(16)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous))

                            SecureField("auth.password", text: $password)
                                .padding(16)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: SageCornerRadius.regular, style: .continuous))

                            if let errorMessage = environment.authStore.errorMessage {
                                Text(errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GlassPrimaryButton(title: mode.buttonKey, systemName: "arrow.right.circle.fill") {
                                Task { @MainActor in
                                    await submit()
                                }
                            }
                            .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty || environment.authStore.isBusy)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func submit() async {
        if mode == .login {
            await environment.authStore.login(username: username, password: password)
        } else {
            await environment.authStore.register(username: username, password: password)
        }
        await environment.authStore.bootstrapApp()
    }
}

private enum AuthMode: CaseIterable, Hashable {
    case login
    case register

    var title: LocalizedStringKey {
        switch self {
        case .login:
            return "auth.mode.login"
        case .register:
            return "auth.mode.register"
        }
    }

    var buttonKey: LocalizedStringKey {
        switch self {
        case .login:
            return "auth.login.submit"
        case .register:
            return "auth.register.submit"
        }
    }

    var subtitleKey: LocalizedStringKey {
        switch self {
        case .login:
            return "auth.login.subtitle"
        case .register:
            return "auth.register.subtitle"
        }
    }
}
