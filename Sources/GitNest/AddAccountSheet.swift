import SwiftUI
import AppKit

/// A value shown on screen alongside a click-to-copy button, so you can *see and
/// verify* exactly what you're copying rather than trusting a silent clipboard
/// write (and spot if another app has tampered with the clipboard).
struct CopyableField: View {
    let value: String
    @State private var copied = false

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
                    .foregroundStyle(copied ? Theme.green : Theme.purpleAccent)
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(8)
        .background(Theme.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Step-by-step wizard that sets up a new GitHub account end to end: sign in,
/// choose a folder, create a dedicated SSH key, guide the key onto GitHub, then
/// write the local config (with backups) and verify.
struct AddAccountSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider().overlay(Theme.border)
            stepContent
            if let error = model.addAccountError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Theme.border)
            footer
        }
        .padding(22)
        .frame(width: 560)
        .background(Theme.surface)
        .interactiveDismissDisabled(model.addAccountBusy && model.addAccountStep == .finish)
    }

    // MARK: Header / step indicator

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Add a GitHub account").font(Theme.title(18))
            Text(stepLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var stepLabel: String {
        switch model.addAccountStep {
        case .signIn: return "Step 1 of 4 — Sign in to GitHub"
        case .folder:  return "Step 2 of 4 — Choose the local folder"
        case .sshKey:  return "Step 3 of 4 — Add the SSH key to GitHub"
        case .finish:  return "Step 4 of 4 — Write config & verify"
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch model.addAccountStep {
        case .signIn: signInStep
        case .folder:  folderStep
        case .sshKey:  sshKeyStep
        case .finish:  finishStep
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to the GitHub account you want to add. Your browser opens to github.com/login/device — enter the one-time code shown below.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let code = model.addAccountDeviceCode {
                Text("One-time code").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                CopyableField(value: code)
            }
            if model.addAccountBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for sign-in to complete…")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = model.addAccountIdentity {
                Label("Signed in as \(id.login)", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
            }
            Text("Choose (or create) the folder where this account's repositories will live. The include rule is written to match it.")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button { chooseFolder() } label: { Label("Choose Folder…", systemImage: "folder") }
                    .buttonStyle(SubtleButtonStyle())
                if let folder = model.addAccountFolder {
                    Text(folder)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Commit email").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                TextField("email", text: $model.addAccountEmail)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
                Text("Defaults to GitHub's private no-reply address — keeps your real email off commits.")
                    .font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var sshKeyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.addAccountKeyCreated
                 ? "A dedicated SSH key was created for this account. Add its public key to GitHub:"
                 : "This account already has a dedicated SSH key. Make sure its public key is on GitHub:")
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let pub = model.addAccountPublicKey {
                Text("Public key").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textTertiary)
                CopyableField(value: pub)
            }
            Button { copyKeyAndOpenGitHub() } label: {
                Label("Copy key & open GitHub SSH settings", systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(SubtleButtonStyle())
            Text("On GitHub: Settings → SSH and GPG keys → New SSH key. Paste, save, then continue.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.addAccountBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing config (with backups) & verifying…")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                if let verification = model.addAccountVerification {
                    Label(sshVerificationText(verification),
                          systemImage: verification.sshOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(verification.sshOK ? Theme.green : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(ghVerificationText(verification),
                          systemImage: verification.ghOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(verification.ghOK ? Theme.green : Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Verification has not run yet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.amber)
                }
                if model.addAccountVerification?.ok != true {
                    Button { Task { await model.addAccountReverify() } } label: {
                        Label("Re-check", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(SubtleButtonStyle())
                }
                Text("Written with timestamped backups of ~/.ssh/config and ~/.gitconfig. The account appears in the sidebar once you're done.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Footer (navigation)

    private var footer: some View {
        HStack {
            Button(model.addAccountStep == .finish ? "Close" : "Cancel") { model.cancelAddAccount() }
                .buttonStyle(SubtleButtonStyle())
                .disabled(model.addAccountBusy && model.addAccountStep == .finish)
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch model.addAccountStep {
        case .signIn:
            Button { Task { await model.addAccountSignIn() } } label: {
                Label("Sign in to GitHub", systemImage: "person.badge.key")
            }
            .buttonStyle(PrimaryPurpleButtonStyle())
            .disabled(model.addAccountBusy)
        case .folder:
            Button { Task { await model.addAccountGenerateKey() } } label: {
                Label("Next", systemImage: "arrow.right")
            }
            .buttonStyle(PrimaryPurpleButtonStyle())
            .disabled(model.addAccountBusy || model.addAccountFolder == nil)
        case .sshKey:
            Button {
                model.addAccountStep = .finish
                model.addAccountBusy = true     // avoid a one-frame "not verified" flash
                Task { await model.addAccountFinish() }
            } label: {
                Label("I've added it — continue", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryPurpleButtonStyle())
            .disabled(model.addAccountBusy)
        case .finish:
            Button { model.completeAddAccount() } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(PrimaryPurpleButtonStyle())
            .disabled(model.addAccountBusy || model.addAccountVerification?.ok != true)
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
            model.setAddAccountFolder(url.path)
        }
    }

    private func copyKeyAndOpenGitHub() {
        if let pub = model.addAccountPublicKey {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pub, forType: .string)
        }
        if let url = URL(string: "https://github.com/settings/ssh/new") {
            NSWorkspace.shared.open(url)
        }
    }
}
