import Foundation
import UIKit
import HealthKit
import BackgroundTasks

// MARK: - OWHHealthStoreProviding

protocol OWHHealthStoreProviding {
    func isHealthDataAvailable() -> Bool
    func execute(_ query: HKQuery)
    func stop(_ query: HKQuery)
    func requestAuthorization(toShare typesToShare: Set<HKSampleType>?, read typesToRead: Set<HKObjectType>?, completion: @escaping (Bool, Error?) -> Void)
    func enableBackgroundDelivery(for type: HKObjectType, frequency: HKUpdateFrequency, withCompletion completion: @escaping (Bool, Error?) -> Void)
    func disableBackgroundDelivery(for type: HKObjectType, withCompletion completion: @escaping (Bool, Error?) -> Void)
}

extension HKHealthStore: OWHHealthStoreProviding {
    func isHealthDataAvailable() -> Bool {
        HKHealthStore.isHealthDataAvailable()
    }
}

// MARK: - OWHNetworkSessionProviding

protocol OWHNetworkSessionProviding {
    func backgroundUploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask
    func foregroundDataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask
}

class OWHDefaultNetworkSession: OWHNetworkSessionProviding {
    private let bgSession: URLSession
    private let fgSession: URLSession

    init(bgSessionId: String, delegate: URLSessionDelegate?) {
        let bgCfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        bgCfg.isDiscretionary = false
        bgCfg.waitsForConnectivity = true
        bgSession = URLSession(configuration: bgCfg, delegate: delegate, delegateQueue: nil)

        let fgCfg = URLSessionConfiguration.default
        fgCfg.timeoutIntervalForRequest = 120
        fgCfg.timeoutIntervalForResource = 600
        fgSession = URLSession(configuration: fgCfg, delegate: nil, delegateQueue: OperationQueue.main)
    }

    func backgroundUploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        bgSession.uploadTask(with: request, fromFile: fileURL)
    }

    func foregroundDataTask(with request: URLRequest, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        fgSession.dataTask(with: request, completionHandler: completionHandler)
    }
}

// MARK: - OWHKeychainProviding

protocol OWHKeychainProviding {
    func getUserId() -> String?
    func getAccessToken() -> String?
    func hasSession() -> Bool
    func clearKeychainIfReinstalled()
    func saveCredentials(userId: String, accessToken: String)
    func saveAppCredentials(appId: String, appSecret: String, baseUrl: String)
    func saveCustomSyncUrl(_ url: String?)
    func getCustomSyncUrl() -> String?
    func getTrackedTypes() -> [String]?
    func saveTrackedTypes(_ types: [String])
    func isSyncActive() -> Bool
    func setSyncActive(_ active: Bool)
    func clearAll()
    func isTokenExpired() -> Bool
    func hasRefreshCredentials() -> Bool
    func getAppId() -> String?
    func getAppSecret() -> String?
    func getBaseUrl() -> String?
    func saveTokenExpiry(_ date: Date)
}

struct OWHKeychainAdapter: OWHKeychainProviding {
    func getUserId() -> String? { OWHKeychain.getUserId() }
    func getAccessToken() -> String? { OWHKeychain.getAccessToken() }
    func hasSession() -> Bool { OWHKeychain.hasSession() }
    func clearKeychainIfReinstalled() { OWHKeychain.clearKeychainIfReinstalled() }
    func saveCredentials(userId: String, accessToken: String) { OWHKeychain.saveCredentials(userId: userId, accessToken: accessToken) }
    func saveAppCredentials(appId: String, appSecret: String, baseUrl: String) { OWHKeychain.saveAppCredentials(appId: appId, appSecret: appSecret, baseUrl: baseUrl) }
    func saveCustomSyncUrl(_ url: String?) { OWHKeychain.saveCustomSyncUrl(url) }
    func getCustomSyncUrl() -> String? { OWHKeychain.getCustomSyncUrl() }
    func getTrackedTypes() -> [String]? { OWHKeychain.getTrackedTypes() }
    func saveTrackedTypes(_ types: [String]) { OWHKeychain.saveTrackedTypes(types) }
    func isSyncActive() -> Bool { OWHKeychain.isSyncActive() }
    func setSyncActive(_ active: Bool) { OWHKeychain.setSyncActive(active) }
    func clearAll() { OWHKeychain.clearAll() }
    func isTokenExpired() -> Bool { OWHKeychain.isTokenExpired() }
    func hasRefreshCredentials() -> Bool { OWHKeychain.hasRefreshCredentials() }
    func getAppId() -> String? { OWHKeychain.getAppId() }
    func getAppSecret() -> String? { OWHKeychain.getAppSecret() }
    func getBaseUrl() -> String? { OWHKeychain.getBaseUrl() }
    func saveTokenExpiry(_ date: Date) { OWHKeychain.saveTokenExpiry(date) }
}

// MARK: - OWHBackgroundTaskProviding

protocol OWHBackgroundTaskProviding {
    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier)
    func registerBGTask(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?, launchHandler: @escaping (BGTask) -> Void)
    func submitBGTask(_ taskRequest: BGTaskRequest) throws
    func cancelAllBGTaskRequests()
}

struct OWHDefaultBackgroundTaskProvider: OWHBackgroundTaskProviding {
    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expirationHandler)
    }

    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }

    func registerBGTask(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?, launchHandler: @escaping (BGTask) -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: queue, launchHandler: launchHandler)
    }

    func submitBGTask(_ taskRequest: BGTaskRequest) throws {
        try BGTaskScheduler.shared.submit(taskRequest)
    }

    func cancelAllBGTaskRequests() {
        BGTaskScheduler.shared.cancelAllTaskRequests()
    }
}

// MARK: - OWHFileManaging

protocol OWHFileManaging {
    func applicationSupportURL() throws -> URL
    var temporaryDirectory: URL { get }
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool, attributes: [FileAttributeKey: Any]?) throws
    func removeItem(at URL: URL) throws
    func removeItem(atPath path: String) throws
    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) throws -> [URL]
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
    func fileExists(atPath path: String) -> Bool
}

extension OWHFileManaging {
    func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool) throws {
        try createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: nil)
    }

    func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?) throws -> [URL] {
        try contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
    }
}

extension FileManager: OWHFileManaging {
    func applicationSupportURL() throws -> URL {
        try url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }
}

// MARK: - OWHDateProviding

protocol OWHDateProviding {
    func now() -> Date
}

struct OWHSystemDateProvider: OWHDateProviding {
    func now() -> Date { Date() }
}
