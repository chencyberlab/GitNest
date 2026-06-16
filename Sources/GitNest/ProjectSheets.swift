import SwiftUI

/// Sheet that previews and confirms the "init-and-push" workflow for a local
/// project folder.
struct InitProjectSheet: View {
    let plan: ProjectInitPlan
    @Binding var initVisibility: RepoVisibilityChoice
    @Binding var moveOriginalToTrash: Bool
    @Binding var initPlan: ProjectInitPlan?
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    /// Builds the warning shown on the init plan sheet from the plan's blocking
    /// reason or mismatched source origin.
    private func planWarning(_ plan: ProjectInitPlan) -> String? {
        if let reason = plan.blockingReason { return reason }
        if let origin = plan.sourceOrigin {
            return "This folder is a clone of a different repo (\(origin)). Its existing Git history will NOT be copied — a fresh repo is created under \(plan.account.alias) so the other repo's history isn't republished."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Initialize & push project")
                .font(Theme.display(18))
                .foregroundStyle(theme.text)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Account:").foregroundStyle(theme.textMuted).frame(width: 90, alignment: .trailing)
                    Text(plan.account.alias).foregroundStyle(theme.text).fontWeight(.medium)
                }
                HStack {
                    Text("Folder:").foregroundStyle(theme.textMuted).frame(width: 90, alignment: .trailing)
                    Text((plan.workingPath as NSString).lastPathComponent)
                        .foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Text("GitHub repo:").foregroundStyle(theme.textMuted).frame(width: 90, alignment: .trailing)
                    Text("\(plan.account.alias)/\(plan.repoName)").foregroundStyle(theme.text).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 12))

            Divider().overlay(theme.border)

            Picker("Visibility", selection: $initVisibility) {
                ForEach(RepoVisibilityChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .pickerStyle(.segmented)

            if plan.willCopy {
                Toggle(isOn: $moveOriginalToTrash) {
                    Text("Move original project folder to Trash after copying it into the account")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.text)
                }
            }

            if let warning = planWarning(plan) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
                    Text(warning)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { initPlan = nil }
                    .buttonStyle(SubtleButtonStyle())
                Button("Init & push") {
                    let plan = plan
                    let visibility = initVisibility
                    let trash = moveOriginalToTrash
                    initPlan = nil
                    Task {
                        await model.projectWorkflow.initProject(
                            plan,
                            visibility: visibility,
                            moveOriginalToTrash: trash
                        )
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(model.isInitializingProject || plan.blockingReason != nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(theme.surface)
    }
}

/// Sheet that collects a GitHub repository address and forks it into the current
/// account.
struct ForkProjectSheet: View {
    @Binding var forkAddress: String
    @Binding var showForkSheet: Bool
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Fork a project")
                .font(Theme.display(18))
                .foregroundStyle(theme.text)

            Text("Enter a GitHub URL (https://github.com/owner/repo) or owner/repo shorthand. The fork will be created under the selected account and cloned into its folder.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            TextField("GitHub repository", text: $forkAddress)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)

            HStack {
                Spacer()
                Button("Cancel") { showForkSheet = false }
                    .buttonStyle(SubtleButtonStyle())
                Button("Fork") {
                    let address = forkAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                    let account = model.selectedAccount
                    showForkSheet = false
                    Task {
                        guard let account else { return }
                        _ = await model.projectWorkflow.forkProject(source: address, account: account)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(forkAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isForkingProject)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(theme.surface)
    }
}
