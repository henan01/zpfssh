import Foundation

/// Provides automatic password injection for the system `/usr/bin/ssh` process.
///
/// How it works (SSH_ASKPASS mechanism — no expect/spawn):
///   1. A tiny askpass helper script is installed in the app-support directory.
///   2. The password is written to a one-time temp file (mode 600).
///   3. SSH is launched directly with two extra env vars:
///        SSH_ASKPASS=/path/to/helper   — helper that prints the password
///        SSH_ASKPASS_REQUIRE=force     — force SSH to call the helper even with a PTY
///      The helper reads the temp file and prints the password to stdout.
///   4. After auth, the interactive session uses the PTY normally.
///
/// Advantages over the previous expect/spawn approach:
///   - No process spawning or pattern-matching — immune to prompt variations
///   - Works with both `password` and `keyboard-interactive` server auth modes
///   - Works on any port and with any host key algorithm (system ssh handles all)
///   - No timing dependency — SSH calls the helper exactly when it needs the password
final class SSHAskPassService: @unchecked Sendable {
    static let shared = SSHAskPassService()

    private let askpassHelper: URL

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent(CredentialService.appSupportID)
        try? FileManager.default.createDirectory(at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        askpassHelper = dir.appendingPathComponent("askpass.sh")
        installAskpassHelper()
    }

    // MARK: - Public API

    /// Returns the env additions needed to inject a saved password into the ssh process,
    /// or nil if the server has no saved password or doesn't use password auth.
    func launchConfig(for server: Server)
        -> (executable: String, args: [String], env: [String: String])?
    {
        guard server.authType == .password,
              let password = CredentialService.shared.load(for: server.id),
              !password.isEmpty else { return nil }

        guard let passTmpURL = writeTempPasswordFile(password) else { return nil }

        // Disable pubkey auth so SSH doesn't try every key in ~/.ssh/ before
        // reaching the password prompt — avoids exhausting MaxAuthTries.
        let extraArgs = [
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=keyboard-interactive,password"
        ]

        return (
            executable: "/usr/bin/ssh",
            args: server.sshArgs(extraArgs: extraArgs),
            env: [
                "SSH_ASKPASS":         askpassHelper.path,
                // force: use the askpass helper even when a PTY is attached
                "SSH_ASKPASS_REQUIRE": "force",
                "ZSSH_PASS_FILE":      passTmpURL.path,
            ]
        )
    }

    // MARK: - Private helpers

    private func installAskpassHelper() {
        // The helper just reads the password file and prints it.
        // SSH calls this program when it needs a password; the output IS the password.
        // Do NOT delete the file here — SSH may call this helper multiple times
        // (retry attempts). The file is cleaned up by the 120-second Swift timer.
        let script = """
        #!/bin/sh
        cat "$ZSSH_PASS_FILE"
        """
        try? script.write(to: askpassHelper, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: askpassHelper.path)
    }

    private func writeTempPasswordFile(_ password: String) -> URL? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(".zssh_\(UUID().uuidString)")
        guard (try? password.write(to: tmp, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // Safety cleanup after 2 minutes in case the helper didn't run
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            try? FileManager.default.removeItem(at: tmp)
        }
        return tmp
    }
}
