import Foundation
import Security

/// Where credentials for outside services go.
///
/// Not UserDefaults. The model key sits there because it usually guards a machine on your
/// own network; a Paperless token is a key to every document you own, readable by anything
/// that can open a plist in your home folder. The difference is worth one small file.
enum Keychain {
    private static let service = "nl.justinmeijer.presort"

    static func set(_ value: String, for account: String) {
        // Written as one item per account, replaced rather than updated: a rewrite is rare
        // and this way there is no path where an old value survives a failed update.
        remove(account)
        guard !value.isEmpty else { return }
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            // Available after the first unlock, and never synced to another Mac: a token
            // for a server on your own network has no business travelling.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, let s = String(data: data, encoding: .utf8)
        else { return "" }
        return s
    }

    static func remove(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
