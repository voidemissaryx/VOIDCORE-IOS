//
//  KeychainStore.swift
//  VOIDCORE VPN
//
//  Thin wrapper around iOS Keychain used for sensitive credentials and
//  configuration secrets (Cloudflare tokens, VLESS UUIDs, MITM CA keys).
//  Mirrors the role Android's `flutter_secure_storage` plugin plays.
//

import Foundation
import Security

/// Items are stored in the keychain, shared with the Packet Tunnel Extension
/// through the access group declared in the entitlements. Both targets can read
/// and write secrets with the same account/service pair.
enum KeychainStore {

    /// Default keychain service prefix. Combined with a key to form the
    /// kSecAttrService value, so unrelated apps can't read our secrets.
    private static let servicePrefix = "com.bpb.voidcore."

    /// The shared access group from the entitlements, or nil when running in a
    /// unit-test context without entitlements (in which case items are private
    /// to the calling process — sufficient for tests).
    private static var accessGroup: String? {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_IDENTIFIER") as? String,
           !identifier.isEmpty {
            return identifier
        }
        return nil
    }

    // MARK: - Public API

    /// Stores `data` under `key`, overwriting any previous value.
    @discardableResult
    static func set(_ data: Data, for key: String) -> Bool {
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        SecItemDelete(query as CFDictionary)
        if accessGroup != nil {
            query[kSecAttrAccessGroup as String] = accessGroup as Any
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Stores `string` as UTF-8 data under `key`.
    @discardableResult
    static func set(_ string: String, for key: String) -> Bool {
        set(Data(string.utf8), for: key)
    }

    /// Returns the data stored under `key`, or nil when missing.
    static func data(for key: String) -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Returns the UTF-8 string stored under `key`, or nil.
    static func string(for key: String) -> String? {
        guard let data = data(for: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes the value for `key`. Safe to call when missing.
    @discardableResult
    static func remove(_ key: String) -> Bool {
        var query = baseQuery(for: key)
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Wipes every VOIDCORE-stored key. Used when the user resets settings.
    static func wipeAll() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix,
        ]
        if let group = accessGroup {
            query[kSecAttrAccessGroup as String] = group
        }
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    private static func baseQuery(for key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + key,
            kSecAttrAccount as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}
