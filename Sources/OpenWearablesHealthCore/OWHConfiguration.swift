import Foundation

/// Configuration options for the sync engine
public struct OWHConfigureOptions {
    public let baseUrl: String
    public let customSyncUrl: String?

    public init(baseUrl: String, customSyncUrl: String? = nil) {
        self.baseUrl = baseUrl
        self.customSyncUrl = customSyncUrl
    }
}

/// Sign-in credentials
public struct OWHSignInOptions {
    public let userId: String
    public let accessToken: String
    public let appId: String?
    public let appSecret: String?
    public let baseUrl: String?

    public init(userId: String, accessToken: String, appId: String? = nil, appSecret: String? = nil, baseUrl: String? = nil) {
        self.userId = userId
        self.accessToken = accessToken
        self.appId = appId
        self.appSecret = appSecret
        self.baseUrl = baseUrl
    }
}
