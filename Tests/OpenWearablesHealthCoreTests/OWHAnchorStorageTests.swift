import XCTest
import HealthKit
@testable import OpenWearablesHealthCore

/// Tests for anchor storage round-trips using UserDefaults.
/// Uses explicit user keys to avoid Keychain dependency (which isn't
/// available in bare SPM test bundles).
final class OWHAnchorStorageTests: XCTestCase {

    private var engine: OWHSyncEngine!
    private let testUserKey = "user.test_anchor_user"

    override func setUp() {
        super.setUp()
        engine = OWHSyncEngine.shared
        engine.trackedTypes = []
    }

    override func tearDown() {
        engine.trackedTypes = []
        UserDefaults.standard.removePersistentDomain(forName: "com.openwearables.healthsdk.state")
        super.tearDown()
    }

    // MARK: - Key generation (explicit params, no keychain)

    func testAnchorKeyWithExplicitUserKey() {
        let key = engine.anchorKey(typeIdentifier: "HKQuantityTypeIdentifierHeartRate", userKey: "user.abc")
        XCTAssertEqual(key, "anchor.user.abc.HKQuantityTypeIdentifierHeartRate")
    }

    func testAnchorKeyIncludesFullTypeIdentifier() {
        let key = engine.anchorKey(typeIdentifier: "HKQuantityTypeIdentifierStepCount", userKey: testUserKey)
        XCTAssertTrue(key.contains("HKQuantityTypeIdentifierStepCount"))
        XCTAssertTrue(key.contains(testUserKey))
    }

    // MARK: - Anchor round-trips via saveAnchorData (takes explicit userKey)

    func testSaveAnchorDataAndReadBack() {
        let stepType = HKObjectType.quantityType(forIdentifier: .stepCount)!
        let anchor = HKQueryAnchor(fromValue: 42)
        let data = try! NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)

        engine.saveAnchorData(data, typeIdentifier: stepType.identifier, userKey: testUserKey)

        let key = engine.anchorKey(typeIdentifier: stepType.identifier, userKey: testUserKey)
        let stored = engine.defaults.data(forKey: key)
        XCTAssertNotNil(stored)

        let restored = try! NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: stored!)
        XCTAssertNotNil(restored)
    }

    func testAnchorsAreScopedPerType() {
        let stepId = HKQuantityTypeIdentifier.stepCount.rawValue
        let hrId = HKQuantityTypeIdentifier.heartRate.rawValue

        let anchor = HKQueryAnchor(fromValue: 1)
        let data = try! NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)

        engine.saveAnchorData(data, typeIdentifier: stepId, userKey: testUserKey)

        let stepKey = engine.anchorKey(typeIdentifier: stepId, userKey: testUserKey)
        let hrKey = engine.anchorKey(typeIdentifier: hrId, userKey: testUserKey)

        XCTAssertNotNil(engine.defaults.data(forKey: stepKey))
        XCTAssertNil(engine.defaults.data(forKey: hrKey))
    }

    func testAnchorsAreScopedPerUser() {
        let stepId = HKQuantityTypeIdentifier.stepCount.rawValue
        let anchor = HKQueryAnchor(fromValue: 7)
        let data = try! NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)

        engine.saveAnchorData(data, typeIdentifier: stepId, userKey: "user.alice")

        let aliceKey = engine.anchorKey(typeIdentifier: stepId, userKey: "user.alice")
        let bobKey = engine.anchorKey(typeIdentifier: stepId, userKey: "user.bob")

        XCTAssertNotNil(engine.defaults.data(forKey: aliceKey))
        XCTAssertNil(engine.defaults.data(forKey: bobKey))
    }

    func testOverwriteAnchor() {
        let stepId = HKQuantityTypeIdentifier.stepCount.rawValue

        let anchor1 = HKQueryAnchor(fromValue: 10)
        let data1 = try! NSKeyedArchiver.archivedData(withRootObject: anchor1, requiringSecureCoding: true)
        engine.saveAnchorData(data1, typeIdentifier: stepId, userKey: testUserKey)

        let anchor2 = HKQueryAnchor(fromValue: 20)
        let data2 = try! NSKeyedArchiver.archivedData(withRootObject: anchor2, requiringSecureCoding: true)
        engine.saveAnchorData(data2, typeIdentifier: stepId, userKey: testUserKey)

        let key = engine.anchorKey(typeIdentifier: stepId, userKey: testUserKey)
        let stored = engine.defaults.data(forKey: key)
        XCTAssertNotNil(stored)
        // Just verify it's valid — we can't inspect the anchor value directly
        let restored = try! NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: stored!)
        XCTAssertNotNil(restored)
    }

    // MARK: - Full-done flag via defaults

    func testFullDoneFlag() {
        let key = "fullDone.\(testUserKey)"
        XCTAssertFalse(engine.defaults.bool(forKey: key))

        engine.defaults.set(true, forKey: key)
        XCTAssertTrue(engine.defaults.bool(forKey: key))

        engine.defaults.set(false, forKey: key)
        XCTAssertFalse(engine.defaults.bool(forKey: key))
    }
}
