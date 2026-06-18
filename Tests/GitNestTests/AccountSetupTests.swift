import XCTest
@testable import GitNest

final class AccountSetupTests: XCTestCase {
    func testContainsHostEntryMatchesRealHostLinesOnly() {
        let config = """
        # Host github-alice
        Host github-alice-old
            HostName github.com

        Host github-bob github-alice
            HostName github.com
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-charlie", in: config))
    }

    func testContainsHostEntryIsCaseInsensitiveAndExact() {
        let config = """
        Host GitHub-Alice
        Host github-alice-extra
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-ali", in: config))
    }

    func testContainsHostEntryIgnoresInlineComments() {
        let config = """
        Host github-alice # this is a comment
            HostName github.com
        Host github-bob # github-alice
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "this", in: config))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-alice", in: "Host github-bob # github-alice"))
    }

    func testContainsHostEntryHandlesQuotedHosts() {
        let config = """
        Host "github-alice"
            HostName github.com
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
    }

    func testContainsHostEntryMatchesWildcardPatterns() {
        let config = """
        Host github-*
            HostName github.com
        """

        XCTAssertTrue(AccountSetup.containsHostEntry(host: "github-alice", in: config))
    }

    func testContainsHostEntryDoesNotMatchUnrelatedWildcardPatterns() {
        let config = """
        Host githubz-*
            HostName github.com
        """

        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-alice", in: config))
    }

    func testContainsHostEntryDoesNotMatchUniversalCatchAll() {
        // The near-universal `Host *` block (kept for AddKeysToAgent/UseKeychain)
        // doesn't configure this host's HostName/IdentityFile, so the wizard must
        // still write its dedicated github-<alias> block — it must NOT count as a
        // pre-existing entry.
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-alice", in: "Host *\n    AddKeysToAgent yes"))
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "*"))
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "?"))
        // A real host-specific wildcard still matches.
        XCTAssertTrue(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "github-*"))
    }

    func testHostMatchesPatternHandlesNegationAndCommaAlternates() {
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "!github-*"))
        XCTAssertTrue(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "!github-bob"))
        XCTAssertTrue(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "github-bob,github-alice"))
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "github-bob,github-carol"))
        // Negated alternates are processed left-to-right: a later positive pattern
        // can re-include a host excluded by an earlier negated one.
        XCTAssertTrue(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "!github-bob,github-alice"))
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-bob", pattern: "!github-bob,github-alice"))
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "github-bob,!github-alice"))
        XCTAssertTrue(AccountSetup.hostMatchesPattern(host: "github-bob", pattern: "github-bob,!github-alice"))
    }

    func testForeignIdentityFilesIgnoresACleanConfig() {
        let config = """
        Host github-alice
            HostName github.com
            IdentityFile ~/.ssh/id_alice
            IdentitiesOnly yes
        """
        XCTAssertEqual(
            AccountSetup.foreignIdentityFiles(host: "github-alice",
                                              expectedKeyPath: "~/.ssh/id_alice",
                                              in: config),
            [])
    }

    func testForeignIdentityFilesFlagsCatchAllAndWildcardBlocks() {
        let config = """
        Host *
            AddKeysToAgent yes
            IdentityFile ~/.ssh/id_rsa

        Host github-*
            IdentityFile ~/.ssh/id_shared   # also offered for github-alice

        Host github-alice
            IdentityFile ~/.ssh/id_alice
        """
        let expand = { ($0 as NSString).expandingTildeInPath }
        XCTAssertEqual(
            AccountSetup.foreignIdentityFiles(host: "github-alice",
                                              expectedKeyPath: "~/.ssh/id_alice",
                                              in: config),
            [expand("~/.ssh/id_rsa"), expand("~/.ssh/id_shared")])
    }

    func testForeignIdentityFilesIgnoresCommentedDirectives() {
        let config = """
        Host *
            # IdentityFile ~/.ssh/id_old
            IdentityFile ~/.ssh/id_rsa

        Host github-alice
            IdentityFile ~/.ssh/id_alice
        """
        let expand = { ($0 as NSString).expandingTildeInPath }
        // id_old is fully commented out → must not be flagged; id_rsa still is.
        XCTAssertEqual(
            AccountSetup.foreignIdentityFiles(host: "github-alice",
                                              expectedKeyPath: "~/.ssh/id_alice",
                                              in: config),
            [expand("~/.ssh/id_rsa")])
    }

    func testContainsHostEntryIgnoresFullyCommentedHostLines() {
        // A whole-line-commented Host must not count as already-configured, or the
        // wizard would skip writing the real block.
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-alice", in: "# Host github-alice"))
        XCTAssertFalse(AccountSetup.containsHostEntry(host: "github-alice", in: "   #Host github-alice"))
    }

    func testForeignIdentityFilesDoesNotAttributeUnrelatedBlocks() {
        let config = """
        Host gitlab.com
            IdentityFile ~/.ssh/id_gitlab

        Host github-bob
            IdentityFile ~/.ssh/id_bob
        """
        XCTAssertEqual(
            AccountSetup.foreignIdentityFiles(host: "github-alice",
                                              expectedKeyPath: "~/.ssh/id_alice",
                                              in: config),
            [])
    }

    func testHostMatchesPatternHonorsBareWildcardOnlyWhenAllowed() {
        // The block-exists check ignores `*`; the IdentityFile check honors it.
        XCTAssertFalse(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "*"))
        XCTAssertTrue(AccountSetup.hostMatchesPattern(host: "github-alice", pattern: "*", allowPureWildcard: true))
    }

    func testFoldersOverlapDetectsSymlinkEquivalentPaths() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestSymlinkOverlap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertTrue(AccountSetup.foldersOverlap(target.path, link.path))
        XCTAssertTrue(AccountSetup.foldersOverlap(link.path, target.path))
    }

    func testFoldersOverlapDetectsSameOrNestedPaths() {
        let home = NSHomeDirectory()
        XCTAssertTrue(AccountSetup.foldersOverlap("\(home)/a", "\(home)/a"))
        XCTAssertTrue(AccountSetup.foldersOverlap("\(home)/a/b", "\(home)/a"))
        XCTAssertTrue(AccountSetup.foldersOverlap("\(home)/a", "\(home)/a/b"))
        XCTAssertFalse(AccountSetup.foldersOverlap("\(home)/a", "\(home)/ab"))
        XCTAssertFalse(AccountSetup.foldersOverlap("\(home)/a/b", "\(home)/a/c"))
    }

    func testSSHLoginParsesGitHubGreeting() {
        let greeting = "Hi Octo-Cat! You've successfully authenticated, but GitHub does not provide shell access."

        XCTAssertEqual(AccountSetup.sshLogin(from: greeting), "Octo-Cat")
        XCTAssertNil(AccountSetup.sshLogin(from: "git@github.com: Permission denied (publickey)."))
    }

    func testAskpassHelperReadsSecretFromInheritedFileDescriptor() {
        let script = AccountSetup.askpassScript()

        XCTAssertTrue(script.contains("/dev/fd/$fd"))
        XCTAssertTrue(script.contains("GITNEST_ASKPASS_FD"))
        XCTAssertFalse(script.contains("GITNEST_ASKPASS_VALUE"))
    }

    func testVerificationRequiresExpectedSSHAndGhLogin() {
        let wrongSSH = AccountSetup.verification(
            expectedAlias: "alice",
            sshText: "Hi bob! You've successfully authenticated.",
            ghLogin: "alice"
        )
        XCTAssertFalse(wrongSSH.sshOK)
        XCTAssertTrue(wrongSSH.ghOK)
        XCTAssertFalse(wrongSSH.ok)

        let wrongGh = AccountSetup.verification(
            expectedAlias: "alice",
            sshText: "Hi Alice! You've successfully authenticated.",
            ghLogin: "bob"
        )
        XCTAssertTrue(wrongGh.sshOK)
        XCTAssertFalse(wrongGh.ghOK)
        XCTAssertFalse(wrongGh.ok)
    }

    func testRestoreWarningIsNilWhenSwitchBackSucceeds() {
        let ok = ShellResult(exitCode: 0, stdout: "", stderr: "")
        XCTAssertNil(AccountSetup.restoreWarning(afterSwitchResult: ok, restoring: "alice"))
    }

    func testRestoreWarningIncludesErrorOutputWhenSwitchBackFails() {
        let failed = ShellResult(exitCode: 1, stdout: "", stderr: "authentication token missing")
        let warning = AccountSetup.restoreWarning(afterSwitchResult: failed, restoring: "alice")
        XCTAssertEqual(warning, "could not restore active gh account to alice: authentication token missing")
    }

    func testBackupDestinationIncludesTimestampAndNonce() {
        let path = "/Users/example/.gitconfig"
        let backup = AccountSetup.backupDestination(for: path,
                                                    timestamp: "20260603-101112",
                                                    nonce: "abcdef12-3456")

        XCTAssertEqual(backup, "/Users/example/.gitconfig.backup-20260603-101112-abcdef12")
    }

    func testIncludeKeysPointingMatchesEveryRuleForTheSameAccountAcrossFolders() {
        // Two folders point at the same per-account config — the stale-rule cleanup
        // must catch both so re-running the wizard can't leave an orphan behind.
        let home = NSHomeDirectory()
        let output = [
            "includeIf.gitdir:~/Developer/github-work/.path\n~/.gitconfig-work",
            "includeIf.gitdir/i:~/CASE/github-work/.path\n~/.gitconfig-work",
            "includeIf.gitdir:~/Old/github-work/.path\n\(home)/.gitconfig-work",
            "includeIf.gitdir:~/Developer/github-home/.path\n~/.gitconfig-home",
        ].joined(separator: "\0") + "\0"

        let keys = AccountSetup.includeKeysPointing(to: "~/.gitconfig-work", inNullDelimited: output)

        XCTAssertEqual(keys, [
            "includeIf.gitdir:~/Developer/github-work/.path",   // portable value
            "includeIf.gitdir/i:~/CASE/github-work/.path",       // case-insensitive gitdir rule
            "includeIf.gitdir:~/Old/github-work/.path",         // expanded value, same file
        ])
    }

    func testIncludeKeysPointingIgnoresUnrelatedKeys() {
        let output = [
            "user.name\nWork User",                                  // not an includeIf rule
            "includeIf.gitdir:~/Developer/github-home/.path\n~/.gitconfig-home",   // different account
            "includeIf.gitdir:~/Developer/github-work/.path\n~/.gitconfig-work",
        ].joined(separator: "\0") + "\0"

        let keys = AccountSetup.includeKeysPointing(to: "~/.gitconfig-work", inNullDelimited: output)

        XCTAssertEqual(keys, ["includeIf.gitdir:~/Developer/github-work/.path"])
    }

    func testWriteGitConfigRejectsFolderOverlappingExistingAccount() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestOverlapTest-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }

        let existing = (root as NSString).appendingPathComponent("existing")
        let nested = (existing as NSString).appendingPathComponent("nested")

        let result = AccountSetup.writeGitConfig(
            alias: "new",
            name: "New",
            email: "new@example.com",
            folder: nested,
            existingAccountFolders: [existing]
        )

        guard case .failure(let error) = result else {
            return XCTFail("Expected failure for overlapping folder")
        }
        XCTAssertTrue(error.message.contains("overlaps"))
    }

    func testRandomPassphraseIsNonEmptyUniqueAndFullEntropy() {
        let a = AccountSetup.randomPassphrase()
        let b = AccountSetup.randomPassphrase()
        XCTAssertFalse(a.isEmpty)
        XCTAssertNotEqual(a, b, "two passphrases must not collide")
        // Decodes back to the requested 32 bytes of entropy.
        XCTAssertEqual(Data(base64Encoded: a)?.count, 32)
        XCTAssertEqual(Data(base64Encoded: AccountSetup.randomPassphrase(byteCount: 16))?.count, 16)
    }

    func testAskpassHelperUsesInheritedFDWithoutEmbeddingASecret() {
        let script = AccountSetup.askpassScript()
        // The helper reads the passphrase from an inherited fd at run time.
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"))
        XCTAssertTrue(script.contains("GITNEST_ASKPASS_FD"))
        XCTAssertTrue(script.contains("/dev/fd/$fd"))
        XCTAssertFalse(script.contains("GITNEST_ASKPASS_VALUE"))
        // The script itself must never contain a literal passphrase.
        let passphrase = AccountSetup.randomPassphrase()
        XCTAssertFalse(script.contains(passphrase))
    }

    func testSSHKeygenPassphraseFlowsThroughStdin() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestSSHKeygenTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let key = root.appendingPathComponent("id_test").path
        let passphrase = "test-passphrase"
        let create = Shell.run(
            ["ssh-keygen", "-t", "ed25519", "-C", "gitnest-test", "-f", key],
            stdin: Data("\(passphrase)\n\(passphrase)\n".utf8),
            displayArgs: ["ssh-keygen", "-t", "ed25519", "-C", "gitnest-test", "-f", key, "-N", Redaction.mask]
        )
        XCTAssertTrue(create.ok, create.stderr + create.stdout)

        let strip = Shell.run(
            ["ssh-keygen", "-p", "-f", key],
            stdin: Data("\(passphrase)\n\n\n".utf8)
        )
        XCTAssertTrue(strip.ok, strip.stderr + strip.stdout)

        let publicKey = Shell.run(["ssh-keygen", "-y", "-f", key])
        XCTAssertTrue(publicKey.ok, publicKey.stderr + publicKey.stdout)
        XCTAssertTrue(publicKey.stdout.hasPrefix("ssh-ed25519 "))
    }

    func testWriteGitConfigRejectsEmptyNameOrEmail() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GitNestEmptyIdentityTest-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: root) }

        let emptyName = AccountSetup.writeGitConfig(
            alias: "new",
            name: "   ",
            email: "new@example.com",
            folder: root
        )
        guard case .failure(let nameError) = emptyName else {
            return XCTFail("Expected failure for empty name")
        }
        XCTAssertTrue(nameError.message.contains("user.name"))

        let emptyEmail = AccountSetup.writeGitConfig(
            alias: "new",
            name: "New",
            email: "  ",
            folder: root
        )
        guard case .failure(let emailError) = emptyEmail else {
            return XCTFail("Expected failure for empty email")
        }
        XCTAssertTrue(emailError.message.contains("user.email"))
    }
}
