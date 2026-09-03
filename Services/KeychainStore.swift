import Foundation
import Security
import os.log

private let log = Logger(subsystem: "com.aria.music", category: "KeychainStore")

/// Minimal Keychain wrapper for the one secret Aria stores: the Subsonic
/// account password.
///
/// Everything else the app persists is user *data* and lives in JSON via
/// `KeyValueStore`. A server password is a real credential — it belongs in the
/// Keychain, not `UserDefaults` (which is plain-text in the app container and
/// lands in unencrypted backups).
///
/// `kSecAttrAccessibleAfterFirstUnlock` so background playback can still reach
/// the server after a reboot the user hasn't unlocked into yet, while keeping
/// the item off the device when locked-and-never-unlocked.
enum KeychainStore {
    /// Namespaced so a future second credential can't collide.
    static let subsonicPasswordAccount = "subsonic.password"

    private static let service = "com.aria.music.credentials"

    /// `true` once a write has failed. A failed write is silent to the user
    /// otherwise — the password simply isn't there on the next launch and the
    /// server appears to un-configure itself — so the UI surfaces this.
    ///
    /// The known cause is a build with no `application-identifier` entitlement
    /// (an unsigned `CODE_SIGNING_ALLOWED=NO` simulator build), where every
    /// Keychain call returns `errSecMissingEntitlement` (-34018). Signed
    /// device and TestFlight builds are unaffected.
    private(set) nonisolated(unsafe) static var lastWriteFailed = false

    @discardableResult
    static func set(_ value: String?, account: String) -> Bool {
        // Empty/nil clears — "no password configured" is a real state.
        guard let value, !value.isEmpty else { return delete(account: account) }

        let data = Data(value.utf8)
        var query = baseQuery(account: account)

        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }

        lastWriteFailed = status != errSecSuccess
        if lastWriteFailed {
            log.error("Keychain write failed for \(account, privacy: .public): OSStatus \(status)")
        }
        return !lastWriteFailed
    }

    static func get(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        let ok = status == errSecSuccess || status == errSecItemNotFound
        lastWriteFailed = !ok
        if !ok {
            log.error("Keychain delete failed for \(account, privacy: .public): OSStatus \(status)")
        }
        return ok
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
