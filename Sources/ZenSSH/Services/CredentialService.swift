import Foundation
import CommonCrypto

/// App-specific encrypted credential storage — no Keychain required.
///
/// Architecture:
///   - A random 256-bit master key is generated once and stored in:
///       ~/Library/Application Support/com.zenlite.ZenSSH/credentials/.master_key
///     with file permissions 600 (owner read/write only).
///   - Passwords are AES-256-CBC encrypted with that key and stored as:
///       ~/Library/Application Support/com.zenlite.ZenSSH/credentials/<serverID>
///     also mode 600.
///   - The entire directory is mode 700.
///   - No Keychain access is needed or requested.
final class CredentialService: @unchecked Sendable {
    static let shared = CredentialService()

    private let credentialsDir: URL
    private lazy var masterKey: Data = loadOrCreateMasterKey()

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

    // MARK: - Master Key (stored in credentials dir, never in Keychain)

    private var masterKeyURL: URL {
        credentialsDir.appendingPathComponent(".master_key")
    }

    private func loadOrCreateMasterKey() -> Data {
        // Try to load existing key
        if let existing = try? Data(contentsOf: masterKeyURL),
           existing.count == kCCKeySizeAES256 {
            return existing
        }
        // Generate new key
        var key = Data(count: kCCKeySizeAES256)
        _ = key.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, kCCKeySizeAES256, $0.baseAddress!)
        }
        try? key.write(to: masterKeyURL)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: masterKeyURL.path)
        return key
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
