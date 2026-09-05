import Foundation
import SwiftUI

struct UnlockView: View {
    @EnvironmentObject private var appState: AppState
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var isConfirmingVaultReplacement = false
    @State private var isConfirmingNewVault = false
    @State private var archivedVaultPendingDeletion: VaultService.ArchivedVault?
    @State private var shouldFocusPassword = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ScrollView {
                    VStack(spacing: 24) {
                        lockHeroBadge

                        passwordField
                            .padding(.top, 6)

                        if let errorMessage = appState.authenticationErrorMessage {
                            Text(errorMessage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.red.opacity(0.82))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        recoveryPanel
                        archivedVaultsPanel
                    }
                    .padding(.horizontal, 44)
                    .padding(.vertical, 40)
                    .frame(maxWidth: 640)
                    .liquidGlassSurface(cornerRadius: 24, tintOpacity: 0.24)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 58)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear {
            shouldFocusPassword = true
        }
        .onChange(of: appState.canReplaceCorruptedVault) { _, canReplace in
            if !canReplace {
                isConfirmingVaultReplacement = false
            }
        }
        .onChange(of: appState.vaultNeedsCreation) { _, needsCreation in
            password = ""
            passwordConfirmation = ""
            isConfirmingNewVault = false
        }
        .onChange(of: appState.credentialResetGeneration) { _, _ in
            password = ""
            passwordConfirmation = ""
            isConfirmingVaultReplacement = false
            isConfirmingNewVault = false
        }
        .alert(
            "Delete Archived Vault?",
            isPresented: archivedVaultDeletionBinding,
            presenting: archivedVaultPendingDeletion
        ) { archivedVault in
            Button("Cancel", role: .cancel) {
                archivedVaultPendingDeletion = nil
            }

            Button("Delete", role: .destructive) {
                appState.deleteArchivedVault(id: archivedVault.id)
                archivedVaultPendingDeletion = nil
            }
        } message: { archivedVault in
            Text("This permanently deletes \(archivedVault.fileName). It cannot be restored from this app.")
        }
    }

    private var lockHeroBadge: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))

            Circle()
                .fill(.clear)
                .glassEffect(
                    .regular.tint(MacPastebinPalette.glassTint.opacity(0.30)),
                    in: Circle()
                )

            Circle()
                .strokeBorder(Color.white.opacity(0.64), lineWidth: 1)
                .padding(1)

            Circle()
                .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                .padding(10)

            Image(systemName: appState.vaultNeedsCreation ? "plus.app" : "lock.fill")
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.48))
                .shadow(color: .white.opacity(0.65), radius: 2, x: 0, y: -1)
        }
        .frame(width: 112, height: 112)
        .shadow(color: .white.opacity(0.18), radius: 6, x: 0, y: -2)
        .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
    }

    private var passwordField: some View {
        VStack(spacing: 12) {
            MacPastebinSecurePasswordField(
                text: $password,
                placeholder: "Password",
                accessibilityLabel: appState.vaultNeedsCreation ? "Create vault password" : "Vault password",
                requestsInitialFocus: shouldFocusPassword,
                resetGeneration: appState.credentialResetGeneration,
                onSubmit: submitPassword
            )
            .frame(height: 48)
            .macPastebinInputChrome(cornerRadius: 24)

            if appState.vaultNeedsCreation {
                MacPastebinSecurePasswordField(
                    text: $passwordConfirmation,
                    placeholder: "Confirm password",
                    accessibilityLabel: "Confirm vault password",
                    requestsInitialFocus: false,
                    resetGeneration: appState.credentialResetGeneration,
                    onSubmit: submitPassword
                )
                .frame(height: 48)
                .macPastebinInputChrome(cornerRadius: 24)

                Text(passwordGuidance)
                    .font(.caption)
                    .foregroundStyle(passwordGuidanceIsError ? .red.opacity(0.82) : MacPastebinPalette.paperInk.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var recoveryPanel: some View {
        if appState.canReplaceCorruptedVault {
            VStack(spacing: 14) {
                if isConfirmingVaultReplacement {
                    Text("This moves the current vault aside and starts a new empty vault.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.62))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        recoveryButton(title: "Cancel", systemImage: "xmark") {
                            isConfirmingVaultReplacement = false
                        }

                        recoveryButton(title: "Replace vault", systemImage: "arrow.clockwise") {
                            password = ""
                            isConfirmingVaultReplacement = false
                            appState.replaceCorruptedVaultAfterConfirmation()
                        }
                    }
                } else {
                    recoveryButton(title: "Replace corrupted vault", systemImage: "exclamationmark.triangle") {
                        isConfirmingVaultReplacement = true
                    }
                }
            }
        } else if !appState.vaultNeedsCreation {
            if isConfirmingNewVault {
                VStack(spacing: 14) {
                    Text("This moves the current encrypted vault aside. It does not delete or decrypt it.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.62))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        recoveryButton(title: "Cancel", systemImage: "xmark") {
                            isConfirmingNewVault = false
                        }

                        recoveryButton(title: "Start new vault", systemImage: "key.slash") {
                            password = ""
                            isConfirmingNewVault = false
                            appState.startNewVaultAfterForgettingPassword()
                        }
                    }
                }
                .frame(maxWidth: 620)
            } else {
                recoveryButton(title: "Start new vault", systemImage: "key.slash") {
                    isConfirmingNewVault = true
                }
            }
        } else {
            Button {
                submitPassword()
            } label: {
                Label("Create vault", systemImage: "plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(MacPastebinPalette.paperInk.opacity(canSubmitPassword ? 0.78 : 0.36))
                    .frame(height: 44)
                    .padding(.horizontal, 22)
            }
            .disabled(!canSubmitPassword)
            .buttonStyle(PuffyGlassButtonStyle(cornerRadius: 22, tintOpacity: 0.30))
        }
    }

    private func recoveryButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.80))
                .frame(height: 44)
                .padding(.horizontal, 22)
        }
        .buttonStyle(PuffyGlassButtonStyle(cornerRadius: 22, tintOpacity: 0.30))
    }

    @ViewBuilder
    private var archivedVaultsPanel: some View {
        if !appState.archivedVaults.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Archived Vaults")
                    .font(.headline)
                    .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.74))

                ForEach(appState.archivedVaults) { archivedVault in
                    HStack(spacing: 10) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.55))
                            .frame(width: 28, height: 28)
                            .macPastebinControlChrome(cornerRadius: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(archivedVault.fileName)
                                .lineLimit(1)
                                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.82))

                            Text(byteCountLabel(archivedVault.byteCount))
                                .font(.caption)
                                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.52))
                        }

                        Spacer()

                        Button("Restore") {
                            password = ""
                            appState.restoreArchivedVault(id: archivedVault.id)
                        }
                        .buttonStyle(MacPastebinButtonStyle())

                        Button("Delete", role: .destructive) {
                            archivedVaultPendingDeletion = archivedVault
                        }
                        .buttonStyle(MacPastebinButtonStyle())
                    }
                    .padding(10)
                    .macPastebinControlChrome(cornerRadius: 12)
                }
            }
            .padding(16)
            .frame(maxWidth: 540)
            .padding(.top, 8)
            .liquidGlassSurface(cornerRadius: 18, tintOpacity: 0.26)
        }
    }

    private func submitPassword() {
        guard canSubmitPassword else {
            return
        }

        let submittedPassword = password
        password = ""
        passwordConfirmation = ""
        appState.createOrUnlockVault(password: submittedPassword)
    }

    private var canSubmitPassword: Bool {
        guard !password.isEmpty else {
            return false
        }
        guard appState.vaultNeedsCreation else {
            return true
        }
        return VaultPasswordPolicy.isAcceptable(password) && password == passwordConfirmation
    }

    private var passwordGuidance: String {
        guard !password.isEmpty else {
            return VaultPasswordPolicy.requirementText
        }
        guard VaultPasswordPolicy.isAcceptable(password) else {
            return VaultPasswordPolicy.requirementText
        }
        guard passwordConfirmation.isEmpty || password == passwordConfirmation else {
            return "Passwords do not match."
        }
        return passwordConfirmation.isEmpty ? "Enter the same password again." : "Passwords match."
    }

    private var passwordGuidanceIsError: Bool {
        (!password.isEmpty && !VaultPasswordPolicy.isAcceptable(password))
            || (!passwordConfirmation.isEmpty && password != passwordConfirmation)
    }

    private func byteCountLabel(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }

    private var archivedVaultDeletionBinding: Binding<Bool> {
        Binding(
            get: { archivedVaultPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    archivedVaultPendingDeletion = nil
                }
            }
        )
    }
}
