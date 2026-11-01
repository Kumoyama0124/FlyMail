import Foundation
import Security

/// 账户密钥（密码/授权码/OAuth 令牌）只存 Keychain，不进 SwiftData。
/// 可随 iCloud 备份恢复：用 AfterFirstUnlock（不带 ThisDeviceOnly），
/// 这样换机用 iCloud 备份恢复后密钥还在，不用每个账户重新输密码；
/// 带 ThisDeviceOnly 的旧密钥会被排除在备份之外，换机就丢了。
/// 后台任务仍可在首次解锁后读取。
enum KeychainStore {
    private static let service = "com.gymbull.AIMail.credentials"

    static func set(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    /// 把旧的 ThisDeviceOnly 密钥重存一遍，改成可备份的级别；
    /// 密钥本身不变，只是换个存储级别，已存的旧项不重存就还是不可备份。
    static func migrateToBackupable(accountID: UUID) {
        for k in ["password", "oauth"] {
            let key = "\(accountID).\(k)"
            if let v = get(key) { set(v, for: key) }
        }
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: key] as CFDictionary)
    }

    static func deleteAll(accountID: UUID) {
        for k in ["password", "oauth"] { delete("\(accountID).\(k)") }
    }
}
