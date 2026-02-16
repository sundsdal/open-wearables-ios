import XCTest
@testable import OpenWearablesHealthCore

/// Tests for OWHKeychain CRUD, token expiry, and reinstall detection.
///
/// These tests require iOS Keychain access, which is not available in bare
/// SPM test bundles (error -34018). They will be skipped automatically in
/// that environment. To run them, use a test host application or an Xcode
/// project with Keychain entitlements.
final class OWHKeychainTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Probe keychain availability — skip entire class if unavailable
        OWHKeychain.saveCredentials(userId: "__probe__", accessToken: "__probe__")
        let available = OWHKeychain.getUserId() != nil
        OWHKeychain.clearAll()
        try XCTSkipUnless(available, "Keychain unavailable in SPM test bundle (needs host application)")

        let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.config")!
        defaults.removeObject(forKey: "appInstalled")
        defaults.synchronize()
    }

    override func tearDown() {
        OWHKeychain.clearAll()
        let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.config")!
        defaults.removeObject(forKey: "appInstalled")
        defaults.synchronize()
        super.tearDown()
    }

    // MARK: - Credentials

    func testSaveAndLoadCredentials() {
        OWHKeychain.saveCredentials(userId: "user123", accessToken: "Bearer tok456")
        XCTAssertEqual(OWHKeychain.getUserId(), "user123")
        XCTAssertEqual(OWHKeychain.getAccessToken(), "Bearer tok456")
    }

    func testOverwriteCredentials() {
        OWHKeychain.saveCredentials(userId: "a", accessToken: "b")
        OWHKeychain.saveCredentials(userId: "c", accessToken: "d")
        XCTAssertEqual(OWHKeychain.getUserId(), "c")
        XCTAssertEqual(OWHKeychain.getAccessToken(), "d")
    }

    func testGetUserIdReturnsNilWhenEmpty() {
        XCTAssertNil(OWHKeychain.getUserId())
    }

    func testGetAccessTokenReturnsNilWhenEmpty() {
        XCTAssertNil(OWHKeychain.getAccessToken())
    }

    // MARK: - hasSession

    func testHasSessionReturnsFalseWhenEmpty() {
        XCTAssertFalse(OWHKeychain.hasSession())
    }

    func testHasSessionReturnsTrueWhenBothSaved() {
        OWHKeychain.saveCredentials(userId: "u", accessToken: "t")
        XCTAssertTrue(OWHKeychain.hasSession())
    }

    // MARK: - clearAll

    func testClearAllRemovesEverything() {
        OWHKeychain.saveCredentials(userId: "u", accessToken: "t")
        OWHKeychain.saveCustomSyncUrl("https://example.com")
        OWHKeychain.setSyncActive(true)
        OWHKeychain.saveTrackedTypes(["steps"])
        OWHKeychain.saveAppCredentials(appId: "a", appSecret: "s", baseUrl: "https://api.test.com")
        OWHKeychain.saveTokenExpiry(Date().addingTimeInterval(3600))

        OWHKeychain.clearAll()

        XCTAssertNil(OWHKeychain.getUserId())
        XCTAssertNil(OWHKeychain.getAccessToken())
        XCTAssertNil(OWHKeychain.getCustomSyncUrl())
        XCTAssertFalse(OWHKeychain.isSyncActive())
        XCTAssertNil(OWHKeychain.getTrackedTypes())
        XCTAssertNil(OWHKeychain.getAppId())
        XCTAssertNil(OWHKeychain.getAppSecret())
        XCTAssertNil(OWHKeychain.getBaseUrl())
    }

    // MARK: - Custom Sync URL

    func testSaveAndLoadCustomSyncUrl() {
        OWHKeychain.saveCustomSyncUrl("https://custom.example.com/sync")
        XCTAssertEqual(OWHKeychain.getCustomSyncUrl(), "https://custom.example.com/sync")
    }

    func testClearCustomSyncUrl() {
        OWHKeychain.saveCustomSyncUrl("https://custom.example.com/sync")
        OWHKeychain.saveCustomSyncUrl(nil)
        XCTAssertNil(OWHKeychain.getCustomSyncUrl())
    }

    // MARK: - Sync Active

    func testSyncActiveDefaultsFalse() {
        XCTAssertFalse(OWHKeychain.isSyncActive())
    }

    func testSetSyncActiveTrue() {
        OWHKeychain.setSyncActive(true)
        XCTAssertTrue(OWHKeychain.isSyncActive())
    }

    func testSetSyncActiveFalseAfterTrue() {
        OWHKeychain.setSyncActive(true)
        OWHKeychain.setSyncActive(false)
        XCTAssertFalse(OWHKeychain.isSyncActive())
    }

    // MARK: - Tracked Types

    func testTrackedTypesDefaultsNil() {
        XCTAssertNil(OWHKeychain.getTrackedTypes())
    }

    func testSaveAndLoadTrackedTypes() {
        let types = ["steps", "heartRate", "sleep"]
        OWHKeychain.saveTrackedTypes(types)
        XCTAssertEqual(OWHKeychain.getTrackedTypes(), types)
    }

    // MARK: - App Credentials

    func testSaveAndLoadAppCredentials() {
        OWHKeychain.saveAppCredentials(appId: "myApp", appSecret: "mySecret", baseUrl: "https://api.test.com")
        XCTAssertEqual(OWHKeychain.getAppId(), "myApp")
        XCTAssertEqual(OWHKeychain.getAppSecret(), "mySecret")
        XCTAssertEqual(OWHKeychain.getBaseUrl(), "https://api.test.com")
    }

    func testHasRefreshCredentialsRequiresAll() {
        XCTAssertFalse(OWHKeychain.hasRefreshCredentials())

        OWHKeychain.saveAppCredentials(appId: "a", appSecret: "s", baseUrl: "https://b.com")
        XCTAssertFalse(OWHKeychain.hasRefreshCredentials()) // still needs userId

        OWHKeychain.saveCredentials(userId: "u1", accessToken: "t1")
        XCTAssertTrue(OWHKeychain.hasRefreshCredentials())
    }

    // MARK: - Token Expiry

    func testTokenExpiryDefaultsNil() {
        XCTAssertNil(OWHKeychain.getTokenExpiry())
    }

    func testIsTokenExpiredWhenNoExpiry() {
        XCTAssertTrue(OWHKeychain.isTokenExpired())
    }

    func testSaveAndLoadTokenExpiry() {
        let future = Date().addingTimeInterval(3600)
        OWHKeychain.saveTokenExpiry(future)
        let loaded = OWHKeychain.getTokenExpiry()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded!.timeIntervalSince1970, future.timeIntervalSince1970, accuracy: 1.0)
    }

    func testIsTokenExpiredWithFarFuture() {
        OWHKeychain.saveTokenExpiry(Date().addingTimeInterval(7200))
        XCTAssertFalse(OWHKeychain.isTokenExpired())
    }

    func testIsTokenExpiredWithPastDate() {
        OWHKeychain.saveTokenExpiry(Date().addingTimeInterval(-3600))
        XCTAssertTrue(OWHKeychain.isTokenExpired())
    }

    func testIsTokenExpiredWithinFiveMinuteBuffer() {
        OWHKeychain.saveTokenExpiry(Date().addingTimeInterval(3 * 60))
        XCTAssertTrue(OWHKeychain.isTokenExpired())
    }

    func testIsTokenExpiredOutsideFiveMinuteBuffer() {
        OWHKeychain.saveTokenExpiry(Date().addingTimeInterval(10 * 60))
        XCTAssertFalse(OWHKeychain.isTokenExpired())
    }

    // MARK: - Reinstall Detection

    func testClearKeychainIfReinstalledClearsStaleData() {
        OWHKeychain.saveCredentials(userId: "old_user", accessToken: "old_token")
        // appInstalled already cleared in setUp → simulates reinstall
        OWHKeychain.clearKeychainIfReinstalled()

        XCTAssertNil(OWHKeychain.getUserId())
        XCTAssertNil(OWHKeychain.getAccessToken())

        let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.config")!
        XCTAssertTrue(defaults.bool(forKey: "appInstalled"))
    }

    func testClearKeychainIfReinstalledPreservesWhenFlagSet() {
        OWHKeychain.saveCredentials(userId: "current", accessToken: "tok")

        let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.config")!
        defaults.set(true, forKey: "appInstalled")
        defaults.synchronize()

        OWHKeychain.clearKeychainIfReinstalled()

        XCTAssertEqual(OWHKeychain.getUserId(), "current")
        XCTAssertEqual(OWHKeychain.getAccessToken(), "tok")
    }
}
