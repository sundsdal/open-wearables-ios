import Foundation
import UIKit
import HealthKit
import BackgroundTasks
import Network

public final class OWHSyncEngine: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {

    public static let shared = OWHSyncEngine()

    // MARK: - Log Handler
    public weak var logHandler: OWHLogHandler?

    // MARK: - Configuration State
    internal var baseUrl: String?
    internal var customSyncUrl: String?

    // MARK: - User State (loaded from Keychain)
    internal var userId: String? { OWHKeychain.getUserId() }
    internal var accessToken: String? { OWHKeychain.getAccessToken() }

    // MARK: - HealthKit State
    internal let healthStore = HKHealthStore()
    internal var session: URLSession!
    internal var foregroundSession: URLSession!
    internal var trackedTypes: [HKSampleType] = []
    internal var chunkSize: Int = 1000
    internal var backgroundChunkSize: Int = 100
    internal var recordsPerChunk: Int = 2000

    // Debouncing
    private var pendingSyncWorkItem: DispatchWorkItem?
    private let syncDebounceQueue = DispatchQueue(label: "health_sync_debounce")
    private var observerBgTask: UIBackgroundTaskIdentifier = .invalid

    // Sync flags
    public var isInitialSyncInProgress = false
    private var isSyncing: Bool = false
    private let syncLock = NSLock()

    // Network monitoring
    private var networkMonitor: NWPathMonitor?
    private let networkMonitorQueue = DispatchQueue(label: "health_sync_network_monitor")
    private var wasDisconnected = false

    // Per-user state (anchors)
    internal let defaults = UserDefaults(suiteName: "com.openwearables.healthsdk.state") ?? .standard

    // Observer queries
    internal var activeObserverQueries: [HKObserverQuery] = []

    // Background session
    internal let bgSessionId = "com.openwearables.healthsdk.upload.session"

    // BGTask identifiers
    internal let refreshTaskId  = "com.openwearables.healthsdk.task.refresh"
    internal let processTaskId  = "com.openwearables.healthsdk.task.process"

    public static var bgCompletionHandler: (() -> Void)?

    // Background response data buffer
    internal var backgroundDataBuffer: [Int: Data] = [:]
    private let bufferLock = NSLock()

    // MARK: - API Endpoints

    internal var syncEndpoint: URL? {
        guard let userId = userId else { return nil }

        if let customUrl = customSyncUrl {
            let urlString = customUrl
                .replacingOccurrences(of: "{userId}", with: userId)
                .replacingOccurrences(of: "{user_id}", with: userId)
            return URL(string: urlString)
        }

        guard let baseUrl = baseUrl else { return nil }
        return URL(string: "\(baseUrl)/api/v1/sdk/users/\(userId)/sync/apple")
    }

    // MARK: - Init
    override init() {
        super.init()

        let bgCfg = URLSessionConfiguration.background(withIdentifier: bgSessionId)
        bgCfg.isDiscretionary = false
        bgCfg.waitsForConnectivity = true
        self.session = URLSession(configuration: bgCfg, delegate: self, delegateQueue: nil)

        let fgCfg = URLSessionConfiguration.default
        fgCfg.timeoutIntervalForRequest = 120
        fgCfg.timeoutIntervalForResource = 600
        fgCfg.waitsForConnectivity = false
        self.foregroundSession = URLSession(configuration: fgCfg, delegate: nil, delegateQueue: OperationQueue.main)

        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskId, using: nil) { [weak self] task in
                self?.handleAppRefresh(task: task as! BGAppRefreshTask)
            }
            BGTaskScheduler.shared.register(forTaskWithIdentifier: processTaskId, using: nil) { [weak self] task in
                self?.handleProcessing(task: task as! BGProcessingTask)
            }
        }
    }

    // MARK: - Public API: Configure

    public func configure(baseUrl: String, customSyncUrl: String? = nil) {
        OWHKeychain.clearKeychainIfReinstalled()

        self.baseUrl = baseUrl

        if let providedCustomUrl = customSyncUrl {
            self.customSyncUrl = providedCustomUrl
            OWHKeychain.saveCustomSyncUrl(providedCustomUrl)
        } else if let storedCustomUrl = OWHKeychain.getCustomSyncUrl() {
            self.customSyncUrl = storedCustomUrl
        }

        if let storedTypes = OWHKeychain.getTrackedTypes() {
            self.trackedTypes = mapTypes(storedTypes)
            logMessage("Restored \(trackedTypes.count) tracked types")
        }

        if let customUrl = self.customSyncUrl {
            logMessage("Configured: customSyncUrl=\(customUrl)")
        } else {
            logMessage("Configured: baseUrl=\(baseUrl)")
        }

        if OWHKeychain.isSyncActive() && OWHKeychain.hasSession() && !trackedTypes.isEmpty {
            logMessage("Auto-restoring background sync...")
            DispatchQueue.main.async { [weak self] in
                self?.autoRestoreSync()
            }
        }
    }

    /// Call this from AppDelegate didFinishLaunchingWithOptions to restore background delivery
    @objc public func restoreOnLaunch() {
        if OWHKeychain.isSyncActive() && OWHKeychain.hasSession() {
            if let storedTypes = OWHKeychain.getTrackedTypes() {
                self.trackedTypes = mapTypes(storedTypes)
            }
            if let storedCustomUrl = OWHKeychain.getCustomSyncUrl() {
                self.customSyncUrl = storedCustomUrl
            }
            if let baseUrl = OWHKeychain.getBaseUrl() {
                self.baseUrl = baseUrl
            }
        }
    }

    // MARK: - Auto Restore Sync
    private func autoRestoreSync() {
        guard userId != nil, accessToken != nil else {
            logMessage("Cannot auto-restore: no session")
            return
        }

        self.startBackgroundDelivery()
        self.startNetworkMonitoring()
        self.scheduleAppRefresh()
        self.scheduleProcessing()

        if hasResumableSyncSession() {
            logMessage("Found interrupted sync, will resume...")
            refreshTokenIfNeeded { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.syncAll(fullExport: false) {
                        self.logMessage("Resumed sync completed")
                    }
                } else {
                    self.logMessage("Token refresh failed, will retry later")
                }
            }
        }

        logMessage("Background sync auto-restored")
    }

    // MARK: - Public API: Sign In

    public func signIn(userId: String, accessToken: String, appId: String? = nil, appSecret: String? = nil, baseUrl: String? = nil) {
        OWHKeychain.saveCredentials(userId: userId, accessToken: accessToken)

        if let appId = appId, let appSecret = appSecret, let baseUrl = baseUrl {
            OWHKeychain.saveAppCredentials(appId: appId, appSecret: appSecret, baseUrl: baseUrl)
            logMessage("App credentials saved for refresh")
        }

        let expiresAt = Date().addingTimeInterval(60 * 60)
        OWHKeychain.saveTokenExpiry(expiresAt)

        logMessage("Signed in: userId=\(userId)")

        self.retryOutboxIfPossible()
    }

    // MARK: - Public API: Sign Out

    public func signOut() {
        logMessage("Signing out")

        stopBackgroundDelivery()
        stopNetworkMonitoring()
        cancelAllBGTasks()

        resetAllAnchors()
        clearSyncSession()
        clearOutbox()

        OWHKeychain.clearAll()

        logMessage("Sign out complete - all sync state reset")
    }

    // MARK: - Public API: Restore Session

    public func restoreSession() -> String? {
        if OWHKeychain.hasSession(),
           let userId = OWHKeychain.getUserId() {
            logMessage("Session restored: userId=\(userId)")
            return userId
        }
        return nil
    }

    // MARK: - Public API: Session Status

    public func isSessionValid() -> Bool {
        return OWHKeychain.hasSession()
    }

    public func isSyncActive() -> Bool {
        return OWHKeychain.isSyncActive()
    }

    public func getStoredCredentials() -> [String: Any?] {
        return [
            "userId": OWHKeychain.getUserId(),
            "accessToken": OWHKeychain.getAccessToken(),
            "customSyncUrl": OWHKeychain.getCustomSyncUrl(),
            "isSyncActive": OWHKeychain.isSyncActive()
        ]
    }

    // MARK: - Public API: Request Authorization

    public func requestAuthorization(types: [String], completion: @escaping (Bool) -> Void) {
        self.trackedTypes = mapTypes(types)
        OWHKeychain.saveTrackedTypes(types)

        logMessage("Requesting auth for \(trackedTypes.count) types")

        requestHealthKitAuthorization { ok in
            completion(ok)
        }
    }

    // MARK: - Public API: Sync Now

    public func syncNow(completion: @escaping () -> Void) {
        self.syncAll(fullExport: false) { completion() }
    }

    // MARK: - Public API: Start Background Sync

    public func startBackgroundSync() -> Bool {
        guard userId != nil, accessToken != nil else {
            return false
        }

        self.startBackgroundDelivery()
        self.startNetworkMonitoring()

        self.initialSyncKickoff { started in
            if started {
                self.logMessage("Sync started")
            } else {
                self.logMessage("Sync failed to start")
                self.isInitialSyncInProgress = false
            }
        }

        self.scheduleAppRefresh()
        self.scheduleProcessing()

        let canStart = HKHealthStore.isHealthDataAvailable() &&
                      self.syncEndpoint != nil &&
                      self.accessToken != nil &&
                      !self.trackedTypes.isEmpty

        if canStart {
            OWHKeychain.setSyncActive(true)
        }

        return canStart
    }

    // MARK: - Public API: Stop Background Sync

    public func stopBackgroundSync() {
        self.stopBackgroundDelivery()
        self.stopNetworkMonitoring()
        self.cancelAllBGTasks()
        OWHKeychain.setSyncActive(false)
    }

    // MARK: - Public API: Reset Anchors

    public func resetAnchors() {
        self.resetAllAnchors()
        self.clearSyncSession()
        self.clearOutbox()
        logMessage("Anchors reset - will perform full sync on next sync")

        if OWHKeychain.isSyncActive() && self.accessToken != nil {
            logMessage("Triggering full export after reset...")
            self.syncAll(fullExport: true) {
                self.logMessage("Full export after reset completed")
            }
        }
    }

    // MARK: - Public API: Resume Sync

    public func resumeSync(completion: @escaping (Result<Void, Error>) -> Void) {
        guard hasResumableSyncSession() else {
            completion(.failure(NSError(domain: "OWHSyncEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "No resumable sync session"])))
            return
        }

        self.syncAll(fullExport: false) {
            completion(.success(()))
        }
    }

    // MARK: - Public API: Background Completion Handler

    @objc public static func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        OWHSyncEngine.bgCompletionHandler = handler
    }

    // MARK: - Get Access Token
    internal func getAccessToken() -> String? {
        return accessToken
    }

    // MARK: - Helper: Get queryable types
    internal func getQueryableTypes() -> [HKSampleType] {
        let disallowedIdentifiers: Set<String> = [
            HKCorrelationTypeIdentifier.bloodPressure.rawValue
        ]

        return trackedTypes.filter { type in
            !disallowedIdentifiers.contains(type.identifier)
        }
    }

    // MARK: - Token Refresh
    internal func refreshTokenIfNeeded(completion: @escaping (Bool) -> Void) {
        guard OWHKeychain.isTokenExpired() else {
            completion(true)
            return
        }

        logMessage("Token expired, refreshing...")

        guard OWHKeychain.hasRefreshCredentials(),
              let appId = OWHKeychain.getAppId(),
              let appSecret = OWHKeychain.getAppSecret(),
              let baseUrl = OWHKeychain.getBaseUrl(),
              let userId = OWHKeychain.getUserId() else {
            logMessage("Missing credentials for token refresh")
            completion(false)
            return
        }

        let urlString = "\(baseUrl)/api/v1/users/\(userId)/token"
        guard let url = URL(string: urlString) else {
            logMessage("Invalid refresh URL")
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["app_id": appId, "app_secret": appSecret]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = foregroundSession.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { completion(false); return }

            if let error = error {
                self.logMessage("Token refresh failed: \(error.localizedDescription)")
                completion(false)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let newToken = json["access_token"] as? String else {
                self.logMessage("Token refresh: invalid response")
                completion(false)
                return
            }

            let fullToken = newToken.hasPrefix("Bearer ") ? newToken : "Bearer \(newToken)"
            OWHKeychain.saveCredentials(userId: userId, accessToken: fullToken)

            let expiresAt = Date().addingTimeInterval(60 * 60)
            OWHKeychain.saveTokenExpiry(expiresAt)

            self.logMessage("Token refreshed successfully")
            completion(true)
        }
        task.resume()
    }

    // MARK: - Authorization
    internal func requestHealthKitAuthorization(completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        let readTypes = Set(getQueryableTypes())

        logMessage("Requesting read-only auth for \(readTypes.count) types")

        healthStore.requestAuthorization(toShare: nil, read: readTypes) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }

    // MARK: - Sync
    internal func syncAll(fullExport: Bool, completion: @escaping () -> Void) {
        guard !trackedTypes.isEmpty else { completion(); return }

        refreshTokenIfNeeded { [weak self] success in
            guard let self = self else { completion(); return }

            guard success else {
                self.logMessage("Token refresh failed, cannot sync")
                completion()
                return
            }

            guard self.accessToken != nil else {
                self.logMessage("No access token for sync")
                completion()
                return
            }
            self.collectAllData(fullExport: fullExport, completion: completion)
        }
    }

    // MARK: - Debounced sync
    internal func triggerCombinedSync() {
        if isInitialSyncInProgress {
            logMessage("Skipping - initial sync in progress")
            return
        }

        if observerBgTask == .invalid {
            observerBgTask = UIApplication.shared.beginBackgroundTask(withName: "health_combined_sync") {
                self.logMessage("Background task expired")
                UIApplication.shared.endBackgroundTask(self.observerBgTask)
                self.observerBgTask = .invalid
            }
        }

        pendingSyncWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.syncAll(fullExport: false) {
                if self.observerBgTask != .invalid {
                    UIApplication.shared.endBackgroundTask(self.observerBgTask)
                    self.observerBgTask = .invalid
                }
            }
        }

        pendingSyncWorkItem = workItem
        syncDebounceQueue.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    // MARK: - Data collection
    internal func collectAllData(fullExport: Bool, completion: @escaping () -> Void) {
        collectAllData(fullExport: fullExport, isBackground: false, completion: completion)
    }

    internal func collectAllData(fullExport: Bool, isBackground: Bool, completion: @escaping () -> Void) {
        syncLock.lock()
        if isSyncing {
            logMessage("Sync in progress, skipping")
            syncLock.unlock()
            completion()
            return
        }
        isSyncing = true
        syncLock.unlock()

        guard HKHealthStore.isHealthDataAvailable() else {
            logMessage("HealthKit not available")
            finishSync()
            completion()
            return
        }

        guard let token = self.accessToken, let endpoint = self.syncEndpoint else {
            logMessage("No token or endpoint")
            finishSync()
            completion()
            return
        }

        let queryableTypes = getQueryableTypes()
        guard !queryableTypes.isEmpty else {
            logMessage("No queryable types")
            finishSync()
            completion()
            return
        }

        let existingState = loadSyncState()
        let isResuming = existingState != nil && existingState!.hasProgress

        if isResuming {
            logMessage("Resuming sync (\(existingState!.totalSentCount) already sent, \(existingState!.completedTypes.count) types done)")
        } else {
            logMessage("Starting streaming sync (fullExport: \(fullExport), \(queryableTypes.count) types)")
            _ = startNewSyncState(fullExport: fullExport, types: queryableTypes)
        }

        let startIndex = isResuming ? getResumeTypeIndex() : 0

        processTypesSequentially(
            types: queryableTypes,
            typeIndex: startIndex,
            fullExport: fullExport,
            endpoint: endpoint,
            token: token,
            isBackground: isBackground
        ) { [weak self] in
            self?.finalizeSyncState()
            self?.finishSync()
            completion()
        }
    }

    private func processTypesSequentially(
        types: [HKSampleType],
        typeIndex: Int,
        fullExport: Bool,
        endpoint: URL,
        token: String,
        isBackground: Bool,
        completion: @escaping () -> Void
    ) {
        guard typeIndex < types.count else {
            completion()
            return
        }

        let type = types[typeIndex]

        if !shouldSyncType(type.identifier) {
            logMessage("Skipping \(shortTypeName(type.identifier)) - already synced")
            processTypesSequentially(
                types: types,
                typeIndex: typeIndex + 1,
                fullExport: fullExport,
                endpoint: endpoint,
                token: token,
                isBackground: isBackground,
                completion: completion
            )
            return
        }

        updateCurrentTypeIndex(typeIndex)

        processTypeStreaming(
            type: type,
            fullExport: fullExport,
            endpoint: endpoint,
            token: token,
            chunkLimit: isBackground ? backgroundChunkSize : recordsPerChunk
        ) { [weak self] success in
            guard let self = self else {
                completion()
                return
            }

            if success {
                self.processTypesSequentially(
                    types: types,
                    typeIndex: typeIndex + 1,
                    fullExport: fullExport,
                    endpoint: endpoint,
                    token: token,
                    isBackground: isBackground,
                    completion: completion
                )
            } else {
                self.logMessage("Sync paused at \(self.shortTypeName(type.identifier)), will resume later")
                self.finishSync()
                completion()
            }
        }
    }

    private func processTypeStreaming(
        type: HKSampleType,
        fullExport: Bool,
        endpoint: URL,
        token: String,
        chunkLimit: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let anchor = fullExport ? nil : loadAnchor(for: type)

        logMessage("\(shortTypeName(type.identifier)): querying...")

        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkLimit) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in

            autoreleasepool {
                guard let self = self else {
                    completion(false)
                    return
                }

                if let error = error {
                    self.logMessage("\(self.shortTypeName(type.identifier)): \(error.localizedDescription)")
                    completion(false)
                    return
                }

                let samples = samplesOrNil ?? []

                if samples.isEmpty {
                    self.logMessage("  \(self.shortTypeName(type.identifier)): complete")
                    self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: nil)
                    completion(true)
                    return
                }

                self.logMessage("  \(self.shortTypeName(type.identifier)): \(samples.count) samples")

                let payload = self.serializeCombinedStreaming(samples: samples)

                var anchorData: Data? = nil
                if let newAnchor = newAnchor {
                    anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                }

                let isLastChunk = samples.count < chunkLimit

                self.sendChunkStreaming(
                    payload: payload,
                    typeIdentifier: type.identifier,
                    sampleCount: samples.count,
                    anchorData: anchorData,
                    isLastChunk: isLastChunk,
                    endpoint: endpoint,
                    token: token
                ) { [weak self] success in
                    guard let self = self else {
                        completion(false)
                        return
                    }

                    if success {
                        if isLastChunk {
                            completion(true)
                        } else {
                            self.processTypeStreamingContinue(
                                type: type,
                                anchor: newAnchor,
                                endpoint: endpoint,
                                token: token,
                                chunkLimit: chunkLimit,
                                completion: completion
                            )
                        }
                    } else {
                        completion(false)
                    }
                }
            }
        }

        healthStore.execute(query)
    }

    private func processTypeStreamingContinue(
        type: HKSampleType,
        anchor: HKQueryAnchor?,
        endpoint: URL,
        token: String,
        chunkLimit: Int,
        completion: @escaping (Bool) -> Void
    ) {
        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkLimit) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in

            autoreleasepool {
                guard let self = self else {
                    completion(false)
                    return
                }

                if let error = error {
                    self.logMessage("\(self.shortTypeName(type.identifier)): \(error.localizedDescription)")
                    completion(false)
                    return
                }

                let samples = samplesOrNil ?? []

                if samples.isEmpty {
                    self.updateTypeProgress(typeIdentifier: type.identifier, sentInChunk: 0, isComplete: true, anchorData: nil)
                    completion(true)
                    return
                }

                self.logMessage("  \(self.shortTypeName(type.identifier)): +\(samples.count) samples")

                let payload = self.serializeCombinedStreaming(samples: samples)

                var anchorData: Data? = nil
                if let newAnchor = newAnchor {
                    anchorData = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true)
                }

                let isLastChunk = samples.count < chunkLimit

                self.sendChunkStreaming(
                    payload: payload,
                    typeIdentifier: type.identifier,
                    sampleCount: samples.count,
                    anchorData: anchorData,
                    isLastChunk: isLastChunk,
                    endpoint: endpoint,
                    token: token
                ) { [weak self] success in
                    guard let self = self else {
                        completion(false)
                        return
                    }

                    if success {
                        if isLastChunk {
                            completion(true)
                        } else {
                            self.processTypeStreamingContinue(
                                type: type,
                                anchor: newAnchor,
                                endpoint: endpoint,
                                token: token,
                                chunkLimit: chunkLimit,
                                completion: completion
                            )
                        }
                    } else {
                        completion(false)
                    }
                }
            }
        }

        healthStore.execute(query)
    }

    private func sendChunkStreaming(
        payload: [String: Any],
        typeIdentifier: String,
        sampleCount: Int,
        anchorData: Data?,
        isLastChunk: Bool,
        endpoint: URL,
        token: String,
        completion: @escaping (Bool) -> Void
    ) {
        enqueueCombinedUpload(
            payload: payload,
            anchors: [:],
            endpoint: endpoint,
            token: token,
            wasFullExport: false
        ) { [weak self] success in
            guard let self = self else {
                completion(false)
                return
            }

            if success {
                self.updateTypeProgress(
                    typeIdentifier: typeIdentifier,
                    sentInChunk: sampleCount,
                    isComplete: isLastChunk,
                    anchorData: isLastChunk ? anchorData : nil
                )
            }

            completion(success)
        }
    }

    private func finishSync() {
        syncLock.lock()
        isSyncing = false
        isInitialSyncInProgress = false
        syncLock.unlock()
    }

    internal func syncType(_ type: HKSampleType, fullExport: Bool, completion: @escaping () -> Void) {
        let anchor = fullExport ? nil : loadAnchor(for: type)

        let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: chunkSize) {
            [weak self] _, samplesOrNil, deletedObjects, newAnchor, error in
            guard let self = self else { completion(); return }
            guard error == nil else { completion(); return }

            let samples = samplesOrNil ?? []
            guard !samples.isEmpty else { completion(); return }

            guard let token = self.accessToken, let endpoint = self.syncEndpoint else {
                completion()
                return
            }

            let payload = self.serialize(samples: samples, type: type)
            self.enqueueBackgroundUpload(payload: payload, type: type, candidateAnchor: newAnchor, endpoint: endpoint, token: token) {
                if samples.count == self.chunkSize {
                    self.syncType(type, fullExport: false, completion: completion)
                } else {
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Logging
    internal func logMessage(_ message: String) {
        NSLog("[OpenWearablesHealthCore] %@", message)

        if let handler = logHandler {
            DispatchQueue.main.async {
                handler.didLog(message)
            }
        }
    }

    internal func logPayloadToConsole(_ data: Data, label: String) {
        #if DEBUG
        if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            NSLog("[OpenWearablesHealthCore] ========== %@ PAYLOAD START ==========", label)
            let chunkSize = 800
            var index = prettyString.startIndex
            while index < prettyString.endIndex {
                let endIndex = prettyString.index(index, offsetBy: chunkSize, limitedBy: prettyString.endIndex) ?? prettyString.endIndex
                let chunk = String(prettyString[index..<endIndex])
                NSLog("[OpenWearablesHealthCore] %@", chunk)
                index = endIndex
            }
            NSLog("[OpenWearablesHealthCore] ========== %@ PAYLOAD END (%d bytes) ==========", label, data.count)
        }
        #endif
    }

    internal func logPayloadSummary(_ data: Data, label: String) {
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let dataDict = jsonObject["data"] as? [String: Any] else {
            let sizeMB = Double(data.count) / (1024 * 1024)
            logMessage("\(label): \(String(format: "%.2f", sizeMB)) MB")
            return
        }

        var summary: [String] = []

        if let records = dataDict["records"] as? [[String: Any]] {
            var typeCounts: [String: Int] = [:]
            for record in records {
                if let type = record["type"] as? String {
                    let shortType = type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                        .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                    typeCounts[shortType, default: 0] += 1
                }
            }
            if !typeCounts.isEmpty {
                let typesList = typeCounts.sorted { $0.value > $1.value }
                    .map { "\($0.key): \($0.value)" }
                    .joined(separator: ", ")
                summary.append("Records: \(records.count) [\(typesList)]")
            }
        }

        if let workouts = dataDict["workouts"] as? [[String: Any]], !workouts.isEmpty {
            var workoutTypes: [String: Int] = [:]
            for workout in workouts {
                if let type = workout["type"] as? String {
                    workoutTypes[type, default: 0] += 1
                }
            }
            let workoutsList = workoutTypes.sorted { $0.value > $1.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            summary.append("Workouts: \(workouts.count) [\(workoutsList)]")
        }

        let sizeMB = Double(data.count) / (1024 * 1024)
        let sizeStr = String(format: "%.2f MB", sizeMB)

        if summary.isEmpty {
            logMessage("\(label): \(sizeStr)")
        } else {
            logMessage("\(label): \(sizeStr) - \(summary.joined(separator: ", "))")
        }
    }

    // MARK: - Network Monitoring

    internal func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }

        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let isConnected = path.status == .satisfied

            if isConnected {
                if self.wasDisconnected {
                    self.wasDisconnected = false
                    self.logMessage("Network restored")
                    self.tryResumeAfterNetworkRestored()
                }
            } else {
                if !self.wasDisconnected {
                    self.wasDisconnected = true
                    self.logMessage("Network lost")
                }
            }
        }

        networkMonitor?.start(queue: networkMonitorQueue)
        logMessage("Network monitoring started")
    }

    internal func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
        wasDisconnected = false
    }

    internal func markNetworkError() {
        wasDisconnected = true
    }

    private func tryResumeAfterNetworkRestored() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }

            guard self.hasResumableSyncSession() else {
                self.logMessage("No sync to resume")
                return
            }

            self.syncLock.lock()
            let alreadySyncing = self.isSyncing
            self.syncLock.unlock()

            if alreadySyncing {
                self.logMessage("Sync already in progress")
                return
            }

            self.logMessage("Resuming sync after network restored...")
            self.refreshTokenIfNeeded { success in
                if success {
                    self.syncAll(fullExport: false) {
                        self.logMessage("Network resume sync completed")
                    }
                } else {
                    self.logMessage("Token refresh failed")
                }
            }
        }
    }

    // MARK: - Helpers
    internal func shortTypeName(_ identifier: String) -> String {
        return identifier
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKWorkoutType", with: "Workout")
    }
}

// MARK: - Array extension
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
