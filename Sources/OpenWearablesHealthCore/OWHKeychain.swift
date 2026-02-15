import Foundation
import Security

/// Secure storage for credentials using iOS Keychain
public class OWHKeychain {

    private static let service = "com.openwearables.healthsdk.tokens"
    private static let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.config") ?? .standard

    // MARK: - Keys
    private static let accessTokenKey = "accessToken"
    private static let userIdKey = "userId"
    private static let appIdKey = "appId"
    private static let appSecretKey = "appSecret"
    private static let tokenExpiresAtKey = "tokenExpiresAt"
    private static let customSyncUrlKey = "customSyncUrl"
    private static let syncActiveKey = "syncActive"
    private static let trackedTypesKey = "trackedTypes"
    private static let appInstalledKey = "appInstalled"
    private static let baseUrlKey = "baseUrl"

    // MARK: - Fresh Install Detection

    /// Call this on app launch to clear Keychain if app was reinstalled.
    /// UserDefaults is cleared on uninstall, but Keychain persists.
    /// If UserDefaults flag is missing but Keychain has data -> app was reinstalled.
    public static func clearKeychainIfReinstalled() {
        let wasInstalled = defaults.bool(forKey: appInstalledKey)

        if !wasInstalled {
            if hasSession() {
                NSLog("[OpenWearablesHealthCore] App reinstalled - clearing stale Keychain data")
                clearAll()
            }
            defaults.set(true, forKey: appInstalledKey)
            defaults.synchronize()
        }
    }

    // MARK: - Save Credentials

    public static func saveCredentials(userId: String, accessToken: String) {
        save(key: userIdKey, value: userId)
        save(key: accessTokenKey, value: accessToken)
    }

    // MARK: - Load Credentials

    public static func getAccessToken() -> String? {
        return load(key: accessTokenKey)
    }

    public static func getUserId() -> String? {
        return load(key: userIdKey)
    }

    public static func hasSession() -> Bool {
        return getAccessToken() != nil && getUserId() != nil
    }

    // MARK: - Custom Sync URL (stored in UserDefaults, not sensitive)

    public static func saveCustomSyncUrl(_ url: String?) {
        if let url = url {
            defaults.set(url, forKey: customSyncUrlKey)
        } else {
            defaults.removeObject(forKey: customSyncUrlKey)
        }
        defaults.synchronize()
    }

    public static func getCustomSyncUrl() -> String? {
        return defaults.string(forKey: customSyncUrlKey)
    }

    // MARK: - Sync Active State

    public static func setSyncActive(_ active: Bool) {
        defaults.set(active, forKey: syncActiveKey)
        defaults.synchronize()
    }

    public static func isSyncActive() -> Bool {
        return defaults.bool(forKey: syncActiveKey)
    }

    // MARK: - Tracked Types

    public static func saveTrackedTypes(_ types: [String]) {
        defaults.set(types, forKey: trackedTypesKey)
        defaults.synchronize()
    }

    public static func getTrackedTypes() -> [String]? {
        return defaults.stringArray(forKey: trackedTypesKey)
    }

    // MARK: - App Credentials (for token refresh)

    public static func saveAppCredentials(appId: String, appSecret: String, baseUrl: String) {
        save(key: appIdKey, value: appId)
        save(key: appSecretKey, value: appSecret)
        defaults.set(baseUrl, forKey: baseUrlKey)
        defaults.synchronize()
    }

    public static func getAppId() -> String? {
        return load(key: appIdKey)
    }

    public static func getAppSecret() -> String? {
        return load(key: appSecretKey)
    }

    public static func getBaseUrl() -> String? {
        return defaults.string(forKey: baseUrlKey)
    }

    // MARK: - Token Expiry

    public static func saveTokenExpiry(_ date: Date) {
        defaults.set(date.timeIntervalSince1970, forKey: tokenExpiresAtKey)
        defaults.synchronize()
    }

    public static func getTokenExpiry() -> Date? {
        let timestamp = defaults.double(forKey: tokenExpiresAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    public static func isTokenExpired() -> Bool {
        guard let expiry = getTokenExpiry() else { return true }
        // Consider expired if less than 5 minutes remaining
        return Date().addingTimeInterval(5 * 60) > expiry
    }

    public static func hasRefreshCredentials() -> Bool {
        return getAppId() != nil && getAppSecret() != nil && getBaseUrl() != nil && getUserId() != nil
    }

    // MARK: - Clear

    public static func clearAll() {
        delete(key: accessTokenKey)
        delete(key: userIdKey)
        delete(key: appIdKey)
        delete(key: appSecretKey)
        defaults.removeObject(forKey: customSyncUrlKey)
        defaults.removeObject(forKey: syncActiveKey)
        defaults.removeObject(forKey: trackedTypesKey)
        defaults.removeObject(forKey: tokenExpiresAtKey)
        defaults.removeObject(forKey: baseUrlKey)
        defaults.synchronize()
    }

    // MARK: - Private Keychain Operations

    private static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("[OpenWearablesHealthCore] Keychain save failed for \(key): \(status)")
        }
    }

    private static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
