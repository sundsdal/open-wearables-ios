import Foundation
import HealthKit

/// Progress tracking per data type - memory efficient
public struct OWHTypeSyncProgress: Codable {
    public let typeIdentifier: String
    public var sentCount: Int
    public var isComplete: Bool
    public var pendingAnchorData: Data?
}

/// Lightweight sync state - tracks progress per type instead of all UUIDs
public struct OWHSyncState: Codable {
    public let userKey: String
    public let fullExport: Bool
    public let createdAt: Date

    public var typeProgress: [String: OWHTypeSyncProgress]
    public var totalSentCount: Int
    public var completedTypes: Set<String>
    public var currentTypeIndex: Int

    public var hasProgress: Bool {
        return totalSentCount > 0 || !completedTypes.isEmpty
    }
}

extension OWHSyncEngine {

    // MARK: - Sync State File

    internal func syncStateDir() -> URL {
        let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return (base ?? FileManager.default.temporaryDirectory).appendingPathComponent("health_sync_state", isDirectory: true)
    }

    internal func ensureSyncStateDir() {
        try? FileManager.default.createDirectory(at: syncStateDir(), withIntermediateDirectories: true)
    }

    internal func syncStateFilePath() -> URL {
        return syncStateDir().appendingPathComponent("state.json")
    }

    internal func anchorsFilePath() -> URL {
        return syncStateDir().appendingPathComponent("anchors.bin")
    }

    // MARK: - Save/Load Sync State

    internal func saveSyncState(_ state: OWHSyncState) {
        ensureSyncStateDir()
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: syncStateFilePath(), options: .atomic)
        }
    }

    internal func loadSyncState() -> OWHSyncState? {
        guard let data = try? Data(contentsOf: syncStateFilePath()),
              let state = try? JSONDecoder().decode(OWHSyncState.self, from: data) else {
            return nil
        }

        guard state.userKey == userKey() else {
            logMessage("Sync state for different user, clearing")
            clearSyncSession()
            return nil
        }

        return state
    }

    internal func updateTypeProgress(typeIdentifier: String, sentInChunk: Int, isComplete: Bool, anchorData: Data?) {
        guard var state = loadSyncState() else { return }

        var progress = state.typeProgress[typeIdentifier] ?? OWHTypeSyncProgress(
            typeIdentifier: typeIdentifier,
            sentCount: 0,
            isComplete: false,
            pendingAnchorData: nil
        )

        progress.sentCount += sentInChunk
        progress.isComplete = isComplete
        if let anchorData = anchorData {
            progress.pendingAnchorData = anchorData
        }

        state.typeProgress[typeIdentifier] = progress
        state.totalSentCount += sentInChunk

        if isComplete {
            state.completedTypes.insert(typeIdentifier)
            if let anchorData = progress.pendingAnchorData {
                saveAnchorData(anchorData, typeIdentifier: typeIdentifier, userKey: state.userKey)
            }
        }

        saveSyncState(state)
    }

    internal func updateCurrentTypeIndex(_ index: Int) {
        guard var state = loadSyncState() else { return }
        state.currentTypeIndex = index
        saveSyncState(state)
    }

    public func clearSyncSession() {
        try? FileManager.default.removeItem(at: syncStateFilePath())
        try? FileManager.default.removeItem(at: anchorsFilePath())
        logMessage("Cleared sync state")
    }

    // MARK: - Start New Sync State

    internal func startNewSyncState(fullExport: Bool, types: [HKSampleType]) -> OWHSyncState {
        let state = OWHSyncState(
            userKey: userKey(),
            fullExport: fullExport,
            createdAt: Date(),
            typeProgress: [:],
            totalSentCount: 0,
            completedTypes: [],
            currentTypeIndex: 0
        )

        saveSyncState(state)
        return state
    }

    // MARK: - Finalize Sync (mark complete)

    internal func finalizeSyncState() {
        guard let state = loadSyncState() else { return }

        if state.fullExport {
            let fullDoneKey = "fullDone.\(state.userKey)"
            defaults.set(true, forKey: fullDoneKey)
            defaults.synchronize()
            logMessage("Marked full export complete")
        }

        logMessage("Sync complete: \(state.totalSentCount) samples across \(state.completedTypes.count) types")
        clearSyncSession()
    }

    // MARK: - Check for Resumable Session

    public func hasResumableSyncSession() -> Bool {
        guard let state = loadSyncState() else { return false }
        return state.hasProgress
    }

    internal func shouldSyncType(_ typeIdentifier: String) -> Bool {
        guard let state = loadSyncState() else { return true }
        return !state.completedTypes.contains(typeIdentifier)
    }

    internal func getResumeTypeIndex() -> Int {
        guard let state = loadSyncState() else { return 0 }
        return state.currentTypeIndex
    }

    // MARK: - Get Sync Status

    public func getSyncStatus() -> [String: Any] {
        if let state = loadSyncState() {
            return [
                "hasResumableSession": state.hasProgress,
                "sentCount": state.totalSentCount,
                "completedTypes": state.completedTypes.count,
                "isFullExport": state.fullExport,
                "createdAt": ISO8601DateFormatter().string(from: state.createdAt)
            ]
        } else {
            return [
                "hasResumableSession": false,
                "sentCount": 0,
                "completedTypes": 0,
                "isFullExport": false,
                "createdAt": NSNull()
            ]
        }
    }
}
