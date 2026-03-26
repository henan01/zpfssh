import Foundation
import CommonCrypto
import Security

/// App-specific encrypted credential storage.
///
/// Architecture
/// ────────────
/// • A random 256-bit AES master key is generated once and stored in the
///   **macOS Keychain** (service "com.zenlite.ZenSSH", account "master-key").
///   It is NOT written to disk, so copying the credentials folder cannot
///   expose passwords.
/// • Passwords are AES-256-CBC encrypted with that key and stored as:
///     ~/Library/Application Support/com.zenlite.ZenSSH/credentials/<serverID>
///   mode 600.
/// • The entire directory is mode 700.
///
/// Migration: if a legacy `.master_key` file is found from an earlier build,
/// its contents are migrated to the Keychain and the file is then deleted.
final class CredentialService: @unchecked Sendable {
    static let shared = CredentialService()

    private let credentialsDir: URL
    private lazy var masterKey: Data = loadOrCreateMasterKey()

    private let keychainService = "com.zenlite.ZenSSH"
    private let keychainAccount = "master-key"

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        credentialsDir = appSupport
            .appendingPathComponent("com.zenlite.ZenSSH")
            .appendingPathComponent("credentials")
        try? FileManager.default.createDirectory(
            at: credentialsDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Public API

    func save(_ password: String, for serverID: UUID) {
        guard !password.isEmpty,
              let data = password.data(using: .utf8),
              let encrypted = aesCBCEncrypt(data, key: masterKey) else { return }
        let file = credPath(serverID)
        try? encrypted.write(to: file)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func load(for serverID: UUID) -> String? {
        let file = credPath(serverID)
        guard let encrypted = try? Data(contentsOf: file),
              let decrypted = aesCBCDecrypt(encrypted, key: masterKey) else { return nil }
        return String(data: decrypted, encoding: .utf8)
    }

    func delete(for serverID: UUID) {
        try? FileManager.default.removeItem(at: credPath(serverID))
    }

    // MARK: - Master Key (stored in macOS Keychain, never on disk)

    /// Legacy file path used by older builds. Only read for migration.
    private var legacyMasterKeyURL: URL {
        credentialsDir.appendingPathComponent(".master_key")
    }

    private func loadOrCreateMasterKey() -> Data {
        // 1. Try Keychain first
        if let existing = keychainLoadKey(), existing.count == kCCKeySizeAES256 {
            // Re-save to upgrade any old item that still has a restrictive ACL
            // (e.g. stored before kSecAttrAccessibleAfterFirstUnlock was set).
            // This is a no-op cost-wise and silently migrates old items.
            keychainSaveKey(existing)
            return existing
        }

        // 2. Migrate from legacy file if present
        if let fileKey = try? Data(contentsOf: legacyMasterKeyURL),
           fileKey.count == kCCKeySizeAES256 {
            keychainSaveKey(fileKey)
            try? FileManager.default.removeItem(at: legacyMasterKeyURL)
            return fileKey
        }

        // 3. Generate a fresh key and store it in Keychain
        var key = Data(count: kCCKeySizeAES256)
        _ = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, kCCKeySizeAES256, $0.baseAddress!)
        }
        keychainSaveKey(key)
        return key
    }

    // MARK: Keychain helpers for the master key

    private func keychainSaveKey(_ key: Data) {
        // kSecAttrAccessibleAfterFirstUnlock: accessible without per-app ACL prompt
        // once the device keychain is first unlocked after boot. This avoids the
        // repeated authorization dialogs that occur with ad-hoc signed builds whose
        // binary hash changes on every rebuild.
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    keychainService,
            kSecAttrAccount:    keychainAccount,
            kSecValueData:      key,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func keychainLoadKey() -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    // MARK: - AES-256-CBC  (IV prepended to ciphertext)

    private func aesCBCEncrypt(_ data: Data, key: Data) -> Data? {
        var iv = Data(count: kCCBlockSizeAES128)
        _ = iv.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, kCCBlockSizeAES128, $0.baseAddress!)
        }

        let bufferSize = data.count + kCCBlockSizeAES128
        var encrypted  = Data(count: bufferSize)
        var outLength  = 0

        let status = encrypted.withUnsafeMutableBytes { encBuf in
            data.withUnsafeBytes { dataBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, kCCKeySizeAES256,
                            ivBuf.baseAddress,
                            dataBuf.baseAddress, data.count,
                            encBuf.baseAddress, bufferSize,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return iv + encrypted.prefix(outLength)
    }

    private func aesCBCDecrypt(_ data: Data, key: Data) -> Data? {
        guard data.count > kCCBlockSizeAES128 else { return nil }
        let iv         = data.prefix(kCCBlockSizeAES128)
        let ciphertext = data.dropFirst(kCCBlockSizeAES128)

        let bufSize = ciphertext.count + kCCBlockSizeAES128
        var decrypted = Data(count: bufSize)
        var outLength = 0

        let ciphertextCopy = Data(ciphertext)
        let ivCopy         = Data(iv)
        let keyCopy        = Data(key)

        let status: CCCryptorStatus = decrypted.withUnsafeMutableBytes { decBuf in
            ciphertextCopy.withUnsafeBytes { cipherBuf in
                keyCopy.withUnsafeBytes { keyBuf in
                    ivCopy.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, kCCKeySizeAES256,
                            ivBuf.baseAddress,
                            cipherBuf.baseAddress, ciphertextCopy.count,
                            decBuf.baseAddress, bufSize,
                            &outLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return decrypted.prefix(outLength)
    }

    // MARK: - Helpers

    private func credPath(_ id: UUID) -> URL {
        credentialsDir.appendingPathComponent(id.uuidString)
    }
}
