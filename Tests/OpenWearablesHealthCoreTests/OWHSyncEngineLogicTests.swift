import XCTest
import HealthKit
@testable import OpenWearablesHealthCore

final class OWHSyncEngineLogicTests: XCTestCase {

    private var engine: OWHSyncEngine!

    override func setUp() {
        super.setUp()
        engine = OWHSyncEngine.shared
        engine.trackedTypes = []
        engine.baseUrl = nil
        engine.customSyncUrl = nil
    }

    override func tearDown() {
        engine.trackedTypes = []
        engine.baseUrl = nil
        engine.customSyncUrl = nil
        super.tearDown()
    }

    // MARK: - shortTypeName

    func testShortTypeNameStripsQuantityPrefix() {
        XCTAssertEqual(engine.shortTypeName("HKQuantityTypeIdentifierStepCount"), "StepCount")
    }

    func testShortTypeNameStripsCategoryPrefix() {
        XCTAssertEqual(engine.shortTypeName("HKCategoryTypeIdentifierSleepAnalysis"), "SleepAnalysis")
    }

    func testShortTypeNameMapsWorkoutType() {
        XCTAssertEqual(engine.shortTypeName("HKWorkoutType"), "Workout")
    }

    func testShortTypeNamePassesThroughUnknown() {
        XCTAssertEqual(engine.shortTypeName("SomethingElse"), "SomethingElse")
    }

    func testShortTypeNameHandlesDoublePrefix() {
        // A string that contains both prefixes (contrived but guards against order issues)
        let input = "HKQuantityTypeIdentifierHKCategoryTypeIdentifierFoo"
        let result = engine.shortTypeName(input)
        XCTAssertEqual(result, "Foo")
    }

    // MARK: - mapTypes

    func testMapTypesKnownTypes() {
        let types = engine.mapTypes(["steps", "heartRate", "sleep", "workout"])
        XCTAssertEqual(types.count, 4)

        let identifiers = Set(types.map { $0.identifier })
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.stepCount.rawValue))
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.heartRate.rawValue))
        XCTAssertTrue(identifiers.contains(HKCategoryTypeIdentifier.sleepAnalysis.rawValue))
        XCTAssertTrue(identifiers.contains("HKWorkoutTypeIdentifier"))
    }

    func testMapTypesUnknownReturnsEmpty() {
        XCTAssertTrue(engine.mapTypes(["nonExistentType"]).isEmpty)
    }

    func testMapTypesEmptyInput() {
        XCTAssertTrue(engine.mapTypes([]).isEmpty)
    }

    func testMapTypesBodyMetrics() {
        let types = engine.mapTypes(["bodyMass", "height", "bmi", "bodyFatPercentage", "leanBodyMass"])
        XCTAssertEqual(types.count, 5)
    }

    func testMapTypesCardioMetrics() {
        let types = engine.mapTypes([
            "heartRate", "restingHeartRate", "heartRateVariabilitySDNN",
            "vo2Max", "oxygenSaturation", "respiratoryRate"
        ])
        XCTAssertEqual(types.count, 6)
    }

    func testMapTypesDietaryMetrics() {
        let types = engine.mapTypes([
            "dietaryEnergyConsumed", "dietaryCarbohydrates",
            "dietaryProtein", "dietaryFatTotal", "dietaryWater"
        ])
        XCTAssertEqual(types.count, 5)
    }

    func testMapTypesAliases() {
        // "restingEnergy" and "basalEnergy" both map to basalEnergyBurned
        let restingTypes = engine.mapTypes(["restingEnergy"])
        let basalTypes = engine.mapTypes(["basalEnergy"])
        XCTAssertEqual(restingTypes.count, 1)
        XCTAssertEqual(basalTypes.count, 1)
        XCTAssertEqual(restingTypes[0].identifier, basalTypes[0].identifier)

        // "bloodOxygen" and "oxygenSaturation" both map to oxygenSaturation
        let bloodO2 = engine.mapTypes(["bloodOxygen"])
        let o2Sat = engine.mapTypes(["oxygenSaturation"])
        XCTAssertEqual(bloodO2[0].identifier, o2Sat[0].identifier)
    }

    func testMapTypesBloodPressureComponents() {
        let types = engine.mapTypes(["bloodPressureSystolic", "bloodPressureDiastolic", "bloodPressure"])
        XCTAssertEqual(types.count, 3)

        let identifiers = Set(types.map { $0.identifier })
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.bloodPressureSystolic.rawValue))
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.bloodPressureDiastolic.rawValue))
        XCTAssertTrue(identifiers.contains(HKCorrelationTypeIdentifier.bloodPressure.rawValue))
    }

    func testMapTypesCategoryTypes() {
        let types = engine.mapTypes(["sleep", "mindfulSession", "menstrualFlow", "cervicalMucusQuality", "ovulationTestResult", "sexualActivity"])
        XCTAssertEqual(types.count, 6)
    }

    func testMapTypesMobilityMetrics() {
        let types = engine.mapTypes([
            "walkingSpeed", "walkingStepLength", "walkingAsymmetryPercentage",
            "walkingDoubleSupportPercentage", "sixMinuteWalkTestDistance"
        ])
        XCTAssertEqual(types.count, 5)
    }

    // MARK: - getQueryableTypes

    func testGetQueryableTypesFiltersBloodPressureCorrelation() {
        engine.trackedTypes = engine.mapTypes(["heartRate", "bloodPressure", "steps"])

        let queryable = engine.getQueryableTypes()
        let identifiers = Set(queryable.map { $0.identifier })

        XCTAssertFalse(identifiers.contains(HKCorrelationTypeIdentifier.bloodPressure.rawValue))
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.heartRate.rawValue))
        XCTAssertTrue(identifiers.contains(HKQuantityTypeIdentifier.stepCount.rawValue))
    }

    func testGetQueryableTypesKeepsBloodPressureComponents() {
        engine.trackedTypes = engine.mapTypes(["bloodPressureSystolic", "bloodPressureDiastolic"])
        let queryable = engine.getQueryableTypes()
        XCTAssertEqual(queryable.count, 2)
    }

    func testGetQueryableTypesPassesThroughNonCorrelations() {
        engine.trackedTypes = engine.mapTypes(["heartRate", "steps"])
        XCTAssertEqual(engine.getQueryableTypes().count, 2)
    }

    func testGetQueryableTypesEmptyWhenNoTrackedTypes() {
        engine.trackedTypes = []
        XCTAssertTrue(engine.getQueryableTypes().isEmpty)
    }

    // MARK: - syncEndpoint (nil cases only — positive cases need Keychain for userId)

    func testSyncEndpointNilWithoutUser() {
        engine.baseUrl = "https://api.example.com"
        XCTAssertNil(engine.syncEndpoint)
    }

    func testSyncEndpointNilWithoutBaseUrl() {
        // userId comes from keychain which is empty
        XCTAssertNil(engine.syncEndpoint)
    }

    // MARK: - Codable: OutboxItem

    func testOutboxItemRoundTrip() {
        let item = OWHSyncEngine.OutboxItem(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount",
            userKey: "user.test",
            payloadPath: "/tmp/payload.json",
            anchorPath: "/tmp/anchor.bin",
            wasFullExport: true
        )

        let data = try! JSONEncoder().encode(item)
        let decoded = try! JSONDecoder().decode(OWHSyncEngine.OutboxItem.self, from: data)

        XCTAssertEqual(decoded.typeIdentifier, item.typeIdentifier)
        XCTAssertEqual(decoded.userKey, item.userKey)
        XCTAssertEqual(decoded.payloadPath, item.payloadPath)
        XCTAssertEqual(decoded.anchorPath, item.anchorPath)
        XCTAssertEqual(decoded.wasFullExport, true)
    }

    func testOutboxItemWithNilOptionals() {
        let item = OWHSyncEngine.OutboxItem(
            typeIdentifier: "combined",
            userKey: "user.x",
            payloadPath: "/tmp/p.json",
            anchorPath: nil,
            wasFullExport: nil
        )

        let data = try! JSONEncoder().encode(item)
        let decoded = try! JSONDecoder().decode(OWHSyncEngine.OutboxItem.self, from: data)

        XCTAssertNil(decoded.anchorPath)
        XCTAssertNil(decoded.wasFullExport)
    }

    // MARK: - Codable: OWHSyncState

    func testSyncStateRoundTrip() {
        let progress = OWHTypeSyncProgress(
            typeIdentifier: "HKQuantityTypeIdentifierStepCount",
            sentCount: 150,
            isComplete: true,
            pendingAnchorData: nil
        )

        let state = OWHSyncState(
            userKey: "user.test",
            fullExport: true,
            createdAt: Date(timeIntervalSince1970: 1700000000),
            typeProgress: ["steps": progress],
            totalSentCount: 150,
            completedTypes: ["HKQuantityTypeIdentifierStepCount"],
            currentTypeIndex: 2
        )

        let data = try! JSONEncoder().encode(state)
        let decoded = try! JSONDecoder().decode(OWHSyncState.self, from: data)

        XCTAssertEqual(decoded.userKey, "user.test")
        XCTAssertTrue(decoded.fullExport)
        XCTAssertEqual(decoded.totalSentCount, 150)
        XCTAssertEqual(decoded.completedTypes, Set(["HKQuantityTypeIdentifierStepCount"]))
        XCTAssertEqual(decoded.currentTypeIndex, 2)
        XCTAssertEqual(decoded.typeProgress["steps"]?.sentCount, 150)
        XCTAssertTrue(decoded.typeProgress["steps"]?.isComplete ?? false)
    }

    func testSyncStateHasProgressWhenSentCountPositive() {
        let state = OWHSyncState(
            userKey: "u", fullExport: false, createdAt: Date(),
            typeProgress: [:], totalSentCount: 10, completedTypes: [], currentTypeIndex: 0
        )
        XCTAssertTrue(state.hasProgress)
    }

    func testSyncStateHasProgressWhenTypesCompleted() {
        let state = OWHSyncState(
            userKey: "u", fullExport: false, createdAt: Date(),
            typeProgress: [:], totalSentCount: 0, completedTypes: ["t1"], currentTypeIndex: 0
        )
        XCTAssertTrue(state.hasProgress)
    }

    func testSyncStateHasNoProgressWhenEmpty() {
        let state = OWHSyncState(
            userKey: "u", fullExport: false, createdAt: Date(),
            typeProgress: [:], totalSentCount: 0, completedTypes: [], currentTypeIndex: 0
        )
        XCTAssertFalse(state.hasProgress)
    }

    // MARK: - Codable: OWHTypeSyncProgress

    func testTypeSyncProgressRoundTrip() {
        let progress = OWHTypeSyncProgress(
            typeIdentifier: "HKQuantityTypeIdentifierHeartRate",
            sentCount: 500,
            isComplete: false,
            pendingAnchorData: Data([0x01, 0x02, 0x03])
        )

        let data = try! JSONEncoder().encode(progress)
        let decoded = try! JSONDecoder().decode(OWHTypeSyncProgress.self, from: data)

        XCTAssertEqual(decoded.typeIdentifier, "HKQuantityTypeIdentifierHeartRate")
        XCTAssertEqual(decoded.sentCount, 500)
        XCTAssertFalse(decoded.isComplete)
        XCTAssertEqual(decoded.pendingAnchorData, Data([0x01, 0x02, 0x03]))
    }

    func testTypeSyncProgressWithNilAnchorData() {
        let progress = OWHTypeSyncProgress(
            typeIdentifier: "t", sentCount: 0, isComplete: false, pendingAnchorData: nil
        )

        let data = try! JSONEncoder().encode(progress)
        let decoded = try! JSONDecoder().decode(OWHTypeSyncProgress.self, from: data)

        XCTAssertNil(decoded.pendingAnchorData)
    }
}
