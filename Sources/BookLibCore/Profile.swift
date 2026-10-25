import Foundation

public struct TokenBearer: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiration: Date

    public init(accessToken: String, refreshToken: String? = nil, expiration: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiration = expiration
    }
}

public struct DeviceInfo: Codable, Sendable, Equatable {
    public var type: String
    public var name: String
    public var serial: String

    public init(type: String = "", name: String = "", serial: String) {
        self.type = type
        self.name = name
        self.serial = serial
    }
}

public struct CustomerInfo: Codable, Sendable, Equatable {
    public var name: String
    public var accountId: String

    public init(name: String, accountId: String) {
        self.name = name
        self.accountId = accountId
    }
}

/// Identifies a registered device/account pair.
public struct ProfileKey: Codable, Sendable, Hashable {
    public var id: UInt32
    public var region: Region
    public var accountId: String
    public var accountName: String
    public var deviceName: String

    public init(id: UInt32, region: Region, accountId: String, accountName: String, deviceName: String) {
        self.id = id
        self.region = region
        self.accountId = accountId
        self.accountName = accountName
        self.deviceName = deviceName
    }

    /// Uniqueness constraint of the original application: customer account and region.
    public func matches(_ other: ProfileKey) -> Bool {
        region == other.region && accountId == other.accountId
    }
}

/// A registered Audible device, including everything needed to sign API requests.
public struct Profile: Codable, Sendable, Identifiable, Equatable {
    public var id: UInt32 = 0
    public var preAmazon: Bool
    public var region: Region
    public var token: TokenBearer?
    public var deviceInfo: DeviceInfo
    public var customerInfo: CustomerInfo?
    public var privateKey: String = ""
    public var adpToken: String = ""
    public var storeAuthCookie: String = ""
    public var cookies: [CookieKV] = []

    // Pending authorization (before registration)
    public var authorizationCode: String?
    public var codeVerifier: String?

    public struct CookieKV: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public init(
        region: Region, preAmazon: Bool, serial: String,
        authorizationCode: String? = nil, codeVerifier: String? = nil
    ) {
        self.region = region
        self.preAmazon = preAmazon
        self.deviceInfo = DeviceInfo(serial: serial)
        self.authorizationCode = authorizationCode
        self.codeVerifier = codeVerifier
    }

    public var key: ProfileKey {
        ProfileKey(
            id: id, region: region,
            accountId: customerInfo?.accountId ?? "",
            accountName: customerInfo?.name ?? "",
            deviceName: deviceInfo.name)
    }

    public func matches(_ key: ProfileKey) -> Bool {
        region == key.region && customerInfo?.accountId == key.accountId
    }

    /// Hosts: api.amazon.<domain> for Amazon accounts, api.audible.<domain> for legacy ones.
    public var authHost: URL {
        URL(string: "https://api.\(preAmazon ? "audible" : "amazon").\(region.domain)")!
    }

    public var audibleHost: URL {
        URL(string: "https://api.audible.\(region.domain)")!
    }
}
