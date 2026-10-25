import Foundation

public enum AuthorizeResult: Int, Sendable, Comparable {
    case none, invalidURL, authorizationFailed, registrationFailed, removeFailed
    case success
    case deregistrationFailed
    case removeProfileFailed

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

public struct RegisterResult: Sendable {
    public var result: AuthorizeResult
    public var newProfileKey: ProfileKey?
    public var previousDeviceName: String?
}

public enum AudibleError: Error, LocalizedError {
    case http(Int, String)
    case invalidResponse(String)
    case noProfile
    case licenseDenied(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(300))")"
        case .invalidResponse(let m): "Unexpected server response: \(m)"
        case .noProfile: "No profile selected."
        case .licenseDenied(let m): "License denied: \(m)"
        }
    }
}

/// Constants the Audible iOS app would send. Version numbers were raised upstream to avoid throttling.
public enum AudibleClientInfo {
    public static let appName = "Audible"
    public static let iosVersion = "26.2"
    public static let appVersion = "4.60"
    public static let softwareVersion = "46000856"
    public static let deviceType = "A2CZJZGLK2JJVM"
    public static let userAgent = "Audible/671 CFNetwork/1240.0.4 Darwin/20.6.0"
}

/// Sign-in via the user's regular browser: build the login URL, accept the redirect URL back.
/// The app never sees the user's credentials.
public struct PendingLogin: Sendable {
    public var region: Region
    public var preAmazon: Bool
    public var serial: String
    public var codeVerifier: String
    public var url: URL
}

public enum AudibleLogin {
    public static func clientId(serial: String) -> String {
        Data("\(serial)#\(AudibleClientInfo.deviceType)".utf8).hexString
    }

    public static func begin(region: Region, preAmazon: Bool) throws -> PendingLogin {
        if preAmazon && !region.allowsPreAmazonAccount {
            throw AudibleError.invalidResponse("Login with username is only supported for DE, US and UK marketplaces.")
        }
        let serial = Crypto.randomSerial()
        let clientId = clientId(serial: serial)
        let verifier = Crypto.randomURLSafeBytes(32)
        let challenge = Crypto.sha256Challenge(for: verifier)
        let domain = region.domain

        let baseURL: String, returnTo: String, assocHandle: String, pageId: String
        if preAmazon {
            baseURL = "https://www.audible.\(domain)/ap/signin"
            returnTo = "https://www.audible.\(domain)/ap/maplanding"
            assocHandle = "amzn_audible_ios_lap_\(region.rawValue)"
            pageId = "amzn_audible_ios_privatepool"
        } else {
            baseURL = "https://www.amazon.\(domain)/ap/signin"
            returnTo = "https://www.amazon.\(domain)/ap/maplanding"
            assocHandle = "amzn_audible_ios_\(region.rawValue)"
            pageId = "amzn_audible_ios"
        }

        let params: [(String, String)] = [
            ("openid.oa2.response_type", "code"),
            ("openid.oa2.code_challenge_method", "S256"),
            ("openid.oa2.code_challenge", challenge),
            ("openid.return_to", returnTo),
            ("openid.assoc_handle", assocHandle),
            ("openid.identity", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("pageId", pageId),
            ("accountStatusPolicy", "P1"),
            ("openid.claimed_id", "http://specs.openid.net/auth/2.0/identifier_select"),
            ("openid.mode", "checkid_setup"),
            ("openid.ns.oa2", "http://www.amazon.com/ap/ext/oauth/2"),
            ("openid.oa2.client_id", "device:\(clientId)"),
            ("openid.ns.pape", "http://specs.openid.net/extensions/pape/1.0"),
            ("marketPlaceId", region.marketPlaceId),
            ("openid.oa2.scope", "device_auth_access"),
            ("forceMobileLayout", "true"),
            ("openid.ns", "http://specs.openid.net/auth/2.0"),
            ("openid.pape.max_auth_age", "0"),
        ]
        let query = params.map { "\(urlEncode($0.0))=\(urlEncode($0.1))" }.joined(separator: "&")
        guard let url = URL(string: "\(baseURL)?\(query)") else { throw AudibleError.invalidResponse("login URL") }
        return PendingLogin(region: region, preAmazon: preAmazon, serial: serial, codeVerifier: verifier, url: url)
    }

    /// Extracts the authorization code from the URL the browser ended up on.
    public static func authorizationCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "openid.oa2.authorization_code" }?.value
    }

    static func urlEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Registration, token refresh and deregistration of the virtual device.
public struct AudibleAuth: Sendable {
    let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) { self.http = http }

    /// Registers the device. On success returns a complete profile (not yet stored).
    public func register(_ login: PendingLogin, authorizationCode: String) async throws -> Profile {
        var profile = Profile(
            region: login.region, preAmazon: login.preAmazon, serial: login.serial,
            authorizationCode: authorizationCode, codeVerifier: login.codeVerifier)

        let body: [String: Any] = [
            "requested_token_type": ["bearer", "mac_dms", "website_cookies", "store_authentication_cookie"],
            "cookies": ["website_cookies": [Any](), "domain": ".amazon.\(login.region.domain)"],
            "registration_data": [
                "domain": "Device",
                "app_version": AudibleClientInfo.appVersion,
                "device_serial": login.serial,
                "device_type": AudibleClientInfo.deviceType,
                "device_name": "%FIRST_NAME%%FIRST_NAME_POSSESSIVE_STRING%%DUPE_STRATEGY_1ST%Audible for iPhone",
                "os_version": AudibleClientInfo.iosVersion,
                "software_version": AudibleClientInfo.softwareVersion,
                "device_model": "iPhone",
                "app_name": AudibleClientInfo.appName,
            ],
            "auth_data": [
                "client_id": AudibleLogin.clientId(serial: login.serial),
                "authorization_code": authorizationCode,
                "code_verifier": login.codeVerifier,
                "code_algorithm": "SHA-256",
                "client_domain": "DeviceLegacy",
            ],
            "requested_extensions": ["device_info", "customer_info"],
        ]
        let json = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: URL(string: profile.authHost.absoluteString + "/auth/register")!)
        req.httpMethod = "POST"
        req.httpBody = json
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await http.send(req)

        try Self.apply(registration: data, to: &profile)
        return profile
    }

    static func apply(registration data: Data, to profile: inout Profile) throws {
        let root = try AudibleJSON.decoder().decode(RegistrationResponse.self, from: data)
        guard let success = root.response?.success,
              let ext = success.extensions, let tokens = success.tokens,
              let device = ext.device_info, let customer = ext.customer_info,
              let mac = tokens.mac_dms, let bearer = tokens.bearer,
              let access = bearer.access_token,
              let userId = customer.user_id
        else { throw AudibleError.invalidResponse("registration response incomplete") }

        profile.deviceInfo = DeviceInfo(
            type: device.device_type ?? AudibleClientInfo.deviceType,
            name: device.device_name ?? "",
            serial: device.device_serial_number ?? profile.deviceInfo.serial)
        profile.customerInfo = CustomerInfo(name: customer.name ?? customer.given_name ?? userId, accountId: userId)
        profile.token = TokenBearer(
            accessToken: access, refreshToken: bearer.refresh_token,
            expiration: Date().addingTimeInterval(Double(bearer.expires_in ?? "") ?? 3600))
        profile.privateKey = mac.device_private_key ?? ""
        profile.adpToken = mac.adp_token ?? ""
        profile.storeAuthCookie = tokens.store_authentication_cookie?.cookie ?? ""
        profile.cookies = (tokens.website_cookies ?? []).compactMap {
            guard let n = $0.Name, let v = $0.Value else { return nil }
            return .init(name: n, value: v.replacingOccurrences(of: "\"", with: ""))
        }
        profile.authorizationCode = nil
        profile.codeVerifier = nil
        guard !profile.privateKey.isEmpty, !profile.adpToken.isEmpty else {
            throw AudibleError.invalidResponse("device credentials missing")
        }
    }

    /// Refreshes the access token if it expires within five minutes. Returns the updated profile.
    public func refreshed(_ profile: Profile) async throws -> Profile {
        var profile = profile
        guard let token = profile.token, let refresh = token.refreshToken else { return profile }
        if Date() < token.expiration.addingTimeInterval(-5 * 60) { return profile }

        let form = [
            "app_name": AudibleClientInfo.appName,
            "app_version": AudibleClientInfo.appVersion,
            "source_token": refresh,
            "requested_token_type": "access_token",
            "source_token_type": "refresh_token",
        ]
        var req = URLRequest(url: URL(string: profile.authHost.absoluteString + "/auth/token")!)
        req.httpMethod = "POST"
        req.httpBody = Data(form.map { "\(AudibleLogin.urlEncode($0.key))=\(AudibleLogin.urlEncode($0.value))" }
            .joined(separator: "&").utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(profile.authHost.host, forHTTPHeaderField: "x-amzn-identity-auth-domain")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await http.send(req)

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String
        else { throw AudibleError.invalidResponse("token response") }
        let expires = (obj["expires_in"] as? Int) ?? Int(obj["expires_in"] as? String ?? "") ?? 3600
        profile.token?.accessToken = access
        profile.token?.expiration = Date().addingTimeInterval(TimeInterval(expires))
        return profile
    }

    public func deregister(_ profile: Profile) async throws {
        let p = try await refreshed(profile)
        guard let token = p.token else { throw AudibleError.noProfile }
        var req = URLRequest(url: URL(string: p.authHost.absoluteString + "/auth/deregister")!)
        req.httpMethod = "POST"
        req.httpBody = Data("deregister_all_existing_accounts=false".utf8)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        _ = try await http.send(req)
    }
}
