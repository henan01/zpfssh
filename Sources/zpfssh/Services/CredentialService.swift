import Foundation
import CommonCrypto
import Security

/// App-specific encrypted credential storage.
///
/// Architecture
/// ────────────
/// • A random 256-bit AES master key is generated once and stored on disk at:
///     ~/Library/Application Support/com.zpf.ssh/credentials/.master_key (mode 600)
///   No keychain is used, so no authorization dialogs ever appear.
/// • Passwords are AES-256-CBC encrypted with that key and stored as:
///     ~/Library/Application Support/com.zpf.ssh/credentials/<serverID>  (mode 600)
/// • The entire directory is mode 700.
final class CredentialService: @unchecked Sendable {
    static let shared = CredentialService()

    private let credentialsDir: URL
    private lazy var masterKey: Data = loadOrCreateMasterKey()

    static let appSupportID = "com.zpf.ssh"

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        credentialsDir = appSupport
            .appendingPathComponent(Self.appSupportID)
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

    // MARK: - Master Key (stored on disk, never in keychain)

    private var masterKeyURL: URL {
        credentialsDir.appendingPathComponent(".master_key")
    }

    private func loadOrCreateMasterKey() -> Data {
        // Try to load existing key from disk
        if let existing = try? Data(contentsOf: masterKeyURL),
           existing.count == kCCKeySizeAES256 {
            return existing
        }

        // Also try legacy keychain migration: if a keychain item exists, migrate to disk
        if let keychainKey = legacyKeychainLoad(), keychainKey.count == kCCKeySizeAES256 {
            writeMasterKeyToDisk(keychainKey)
            legacyKeychainDelete()
            return keychainKey
        }

        // Generate a fresh key and save it to disk
        var key = Data(count: kCCKeySizeAES256)
        _ = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, kCCKeySizeAES256, $0.baseAddress!)
        }
        writeMasterKeyToDisk(key)
        return key
    }

    private func writeMasterKeyToDisk(_ key: Data) {
        try? key.write(to: masterKeyURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: masterKeyURL.path)
    }

    // MARK: - Legacy keychain migration helpers (read-only, one-time)

    private func legacyKeychainLoad() -> Data? {
        for service in ["com.zenlite.ZenSSH", "com.zpf.ssh"] {
            let query: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: "master-key",
                kSecReturnData:  true,
                kSecMatchLimit:  kSecMatchLimitOne,
            ]
            var result: AnyObject?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data {
                return data
            }
        }
        return nil
    }

    private func legacyKeychainDelete() {
        for service in ["com.zenlite.ZenSSH", "com.zpf.ssh"] {
            let q: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: "master-key",
            ]
            SecItemDelete(q as CFDictionary)
        }
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
