import Foundation

/// Result of the `gh auth login` step during the add-account flow.
struct AddAccountLoginResult: Sendable {
    let login: ShellResult
    let identity: Result<AccountSetup.Identity, CommandError>?
}
