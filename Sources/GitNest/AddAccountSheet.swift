import SwiftUI
import AppKit

/// A value shown on screen alongside a click-to-copy button, so you can *see and
/// verify* exactly what you're copying rather than trusting a silent clipboard
/// write (and spot if another app has tampered with the clipboard).
struct CopyableField: View {
    let value: String
    @State private var copied = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.vertical) {
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 60)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(copied ? theme.success : theme.accent)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(8)
        .background(theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1))
    }
}

/// Step-by-step wizard that sets up a new GitHub account end to end: sign in,
/// choose a folder, create a dedicated SSH key, guide the key onto GitHub, then
/// write the local config (with backups) and verify.
struct AddAccountSheet: View {
    @EnvironmentObject var setupCoordinator: SetupCoordinator
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().overlay(theme.border)
            stepContent
            if let error = setupCoordinator.addAccountError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(theme.border)
            footer
        }
        .padding(22)
        .frame(width: 560)
        .background(theme.surface)
        .interactiveDismissDisabled(setupCoordinator.addAccountBusy)
    }

    // MARK: Header / step indicator

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Add a GitHub account").font(Theme.title(18))
            Text(stepLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textMuted)
        }
    }

    private var stepLabel: String {
        switch setupCoordinator.addAccountStep {
        case .signIn: return "Step 1 of 4 — Sign in to GitHub"
        case .folder:  return "Step 2 of 4 — Choose the local folder"
        case .sshKey:  return "Step 3 of 4 — Add the SSH key to GitHub"
        case .finish:  return "Step 4 of 4 — Write config & verify"
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch setupCoordinator.addAccountStep {
        case .signIn: signInStep
        case .folder:  folderStep
        case .sshKey:  sshKeyStep
        case .finish:  finishStep
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to the GitHub account you want to add. Your browser opens to github.com/login/device — enter the one-time code shown below.")
                .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let code = setupCoordinator.addAccountDeviceCode {
                Text("One-time code").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
                CopyableField(value: code)
            }
            if setupCoordinator.addAccountBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in to complete…")
                        .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                }
            }
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = setupCoordinator.addAccountIdentity {
                Label("Signed in as \(id.login)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.success)
            }
            Text("Choose (or create) the folder where this account's repositories will live. The include rule is written to match it.")
                .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
                    .buttonStyle(SubtleButtonStyle())
                if let folder = setupCoordinator.addAccountFolder {
                    Text(folder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Commit email").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
                TextField("email", text: $setupCoordinator.addAccountEmail)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                Text("Defaults to GitHub's private no-reply address — keeps your real email off commits.")
                    .font(.system(size: 10)).foregroundStyle(theme.textTertiary)
            }
            Label("The SSH key is encrypted with a random passphrase saved to your login Keychain, so Git runs unattended while the private key stays protected at rest. (If the agent can't be reached it falls back to file-permission protection only.)",
                  systemImage: "lock")
                .font(.system(size: 11))
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sshKeyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(setupCoordinator.addAccountKeyCreated
                 ? "A dedicated SSH key was created for this account. Add its public key to GitHub:"
                 : "This account already has a dedicated SSH key. Make sure its public key is on GitHub:")
                .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if setupCoordinator.addAccountKeyCreated && !setupCoordinator.addAccountKeyHardened {
                Label("This key couldn't be encrypted — the login Keychain / ssh-agent wasn't reachable, so it's protected by file permissions only. It still works, but anyone who can read the private key file could use it. Re-run setup once your Keychain/ssh-agent is available to encrypt it.",
                      systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let pub = setupCoordinator.addAccountPublicKey {
                Text("Public key").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textTertiary)
                CopyableField(value: pub)
            }
            Button { copyKeyAndOpenGitHub() } label: {
                Label("Copy key & open GitHub SSH settings", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(SubtleButtonStyle())
            Text("On GitHub: Settings → SSH and GPG keys → New SSH key. Paste, save, then continue.")
                .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if setupCoordinator.addAccountBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing config (with backups) & verifying…")
                        .font(.system(size: 12)).foregroundStyle(theme.textMuted)
                }
            } else {
                if let verification = setupCoordinator.addAccountVerification {
                    Label(sshVerificationText(verification),
                          systemImage: verification.sshOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(verification.sshOK ? theme.success : theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(ghVerificationText(verification),
                          systemImage: verification.ghOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(verification.ghOK ? theme.success : theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Verification has not run yet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.warning)
                }
                if setupCoordinator.addAccountVerification?.ok != true {
                    Button { Task { await setupCoordinator.addAccountReverify() } } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                Text("Written with timestamped backups of ~/.ssh/config and ~/.gitconfig. The account appears in the sidebar once you're done.")
                    .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer (navigation)

    private var footer: some View {
        HStack {
            Button(setupCoordinator.addAccountStep == .finish ? "Close" : "Cancel") { setupCoordinator.cancelAddAccount() }
                .buttonStyle(SubtleButtonStyle())
                // Only block cancellation during the .finish config-write window,
                // which mutates ~/.ssh/config and ~/.gitconfig across two awaits and
                // must not be interrupted. The sign-in step is also "busy", but its
                // gh auth poll can run for minutes and is *designed* to be cancellable
                // (cancelAddAccount kills it and frees the gh chain) — keep Cancel
                // enabled there so the user is never locked out of aborting sign-in.
                .disabled(setupCoordinator.addAccountBusy && setupCoordinator.addAccountStep == .finish)
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch setupCoordinator.addAccountStep {
        case .signIn:
            Button { Task { await setupCoordinator.addAccountSignIn() } } label: {
                Label("Sign in to GitHub", systemImage: "person.badge.key")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(setupCoordinator.addAccountBusy)
        case .folder:
            Button { Task { await setupCoordinator.addAccountGenerateKey() } } label: {
                Label("Next", systemImage: "arrow.right")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(setupCoordinator.addAccountBusy || setupCoordinator.addAccountFolder == nil)
        case .sshKey:
            Button {
                setupCoordinator.addAccountStep = .finish
                setupCoordinator.addAccountBusy = true     // avoid a one-frame "not verified" flash
                Task { await setupCoordinator.addAccountFinish() }
            } label: {
                Label("I've added it — continue", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(setupCoordinator.addAccountBusy)
        case .finish:
            Button { setupCoordinator.completeAddAccount() } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(setupCoordinator.addAccountBusy || setupCoordinator.addAccountVerification?.ok != true)
        }
    }

    // MARK: Actions

    private func sshVerificationText(_ verification: AccountSetup.Verification) -> String {
        if verification.sshOK {
            return "SSH authenticates as \(verification.expectedAlias) via github-\(verification.expectedAlias)"
        }
        if let login = verification.sshLogin {
            return "SSH authenticated as \(login), expected \(verification.expectedAlias)"
        }
        return "SSH not verified yet — the key can take a moment to register on GitHub."
    }

    private func ghVerificationText(_ verification: AccountSetup.Verification) -> String {
        if verification.ghOK {
            return "GitHub CLI active as \(verification.expectedAlias)"
        }
        if let login = verification.ghLogin {
            return "GitHub CLI active as \(login), expected \(verification.expectedAlias)"
        }
        return "GitHub CLI active account could not be verified."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Account Folder"
        panel.message = "Choose or create the folder for this account's repositories."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())   // device-portable default
        if panel.runModal() == .OK, let url = panel.url {
            let chosen = url.path
            if let overlap = setupCoordinator.accounts.first(where: { AccountSetup.foldersOverlap(chosen, $0.folder) }) {
                // Clear any previously chosen folder so the error can't sit next to a
                // still-valid selection with Next left enabled (which would let the
                // user proceed with the old folder while seeing an error about the new one).
                setupCoordinator.setAddAccountFolder(nil)
                setupCoordinator.setAddAccountError(
                    "The chosen folder overlaps with \(overlap.alias)'s folder (\(overlap.folder)). Pick a separate location."
                )
            } else {
                setupCoordinator.addAccountError = nil
                setupCoordinator.setAddAccountFolder(chosen)
            }
        }
    }

    private func copyKeyAndOpenGitHub() {
        if let pub = setupCoordinator.addAccountPublicKey {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pub, forType: .string)
        }
        if let url = URL(string: "https://github.com/settings/ssh/new") {
            NSWorkspace.shared.open(url)
        }
    }
}
