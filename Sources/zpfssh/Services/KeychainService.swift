import Foundation
import Security

final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()
    private let service = "com.zpf.ssh"
    private init() {}

    func savePassword(_ password: String, for serverID: UUID) {
        let key = "ssh-password-\(serverID.uuidString)"
        let data = password.data(using: .utf8)!
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecValueData: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    func loadPassword(for serverID: UUID) -> String? {
        let key = "ssh-password-\(serverID.uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func deletePassword(for serverID: UUID) {
        let key = "ssh-password-\(serverID.uuidString)"
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
