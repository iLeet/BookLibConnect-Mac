import Foundation

/// Signed access to the Audible API for one registered device.
public struct AudibleAPI: Sendable {
    public let profile: Profile
    let http: HTTPClient

    public init(profile: Profile, http: HTTPClient = HTTPClient()) {
        self.profile = profile
        self.http = http
    }

    // MARK: - Library

    static let libraryGroups =
        "response_groups=badge_types,category_ladders,claim_code_url,contributors,is_downloaded,is_returnable,media,"
        + "origin_asin,pdf_url,percent_complete,price,product_attrs,product_desc,product_extended_attrs,product_plan_details,"
        + "product_plans,provided_review,rating,relationships,review_attrs,reviews,sample,series,sku"

    /// Fetches all library pages purchased after `purchasedAfter`, oldest first, de-duplicated.
    public func library(
        purchasedAfter: Date,
        onPage: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [Product] {
        let pageSize = 100
        var page = 0
        var products: [Product] = []
        while true {
            try Task.checkCancellation()
            page += 1
            let rel = "/1.0/library?purchased_after=\(DateParsing.xmlString(purchasedAfter))"
                + "&num_results=\(pageSize)&page=\(page)&\(Self.libraryGroups)"
            let data = try await signedGet(rel)
            let response = try AudibleJSON.decoder().decode(LibraryResponse.self, from: data)
            guard let items = response.items, !items.isEmpty else { break }
            products.append(contentsOf: items)
            onPage?(page, products.count)
        }
        var seen = Set<String>()
        products = products.filter { p in
            guard let a = p.asin else { return false }
            return seen.insert(a).inserted
        }
        products.sort { ($0.purchase_date ?? .distantPast) < ($1.purchase_date ?? .distantPast) }
        return products
    }

    public func product(asin: String) async throws -> Product? {
        let groups = "response_groups=contributors,media,product_attrs,product_desc,product_extended_attrs,"
            + "product_plan_details,product_plans,rating,review_attrs,reviews,sample,sku"
        let data = try await signedGet("/1.0/catalog/products/\(asin)?\(groups)")
        return try AudibleJSON.decoder().decode(ProductResponse.self, from: data).product
    }

    public func accountInfo() async throws -> Data {
        let groups = "response_groups=migration_details,subscription_details_rodizio,"
            + "subscription_details_premium,customer_segment,subscription_details_channels"
        return try await signedGet("/1.0/customer/information?\(groups)")
    }

    // MARK: - Licensing

    public struct GrantedLicense: Sendable {
        public var license: ContentLicense
        public var voucher: Voucher
    }

    public func licenseRequest(asin: String, quality: DownloadQuality) async throws -> GrantedLicense {
        let body = #"{"consumption_type":"Download","supported_drm_types":["Adrm","Mpeg"],"quality":""#
            + quality.apiName
            + #"","response_groups":"last_position_heard,pdf_url,content_reference,chapter_info"}"#
        let data = try await signedRequest("/1.0/content/\(asin)/licenserequest", body: body)
        guard let license = try AudibleJSON.decoder().decode(LicenseResponse.self, from: data).content_license else {
            throw AudibleError.licenseDenied("empty response")
        }
        guard license.status_code == "Granted" else {
            throw AudibleError.licenseDenied(license.message ?? license.status_code ?? "unknown")
        }
        guard let response = license.license_response, let customer = profile.customerInfo else {
            throw AudibleError.licenseDenied("no voucher")
        }
        let voucher = try Crypto.decryptVoucher(
            licenseResponse: response, deviceType: profile.deviceInfo.type,
            deviceSerial: profile.deviceInfo.serial, customerId: customer.accountId,
            asin: license.asin ?? asin)
        return GrantedLicense(license: license, voucher: voucher)
    }

    // MARK: - Download

    /// Downloads the encrypted audio file. Returns the number of bytes written.
    public func download(
        from url: URL, to destination: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> Int64 {
        var req = URLRequest(url: url)
        req.setValue(AudibleClientInfo.userAgent, forHTTPHeaderField: "User-Agent")
        return try await FileDownloader.download(req, to: destination, progress: progress)
    }

    public func coverImage(url: URL) async -> Data? { await http.imageData(from: url) }

    // MARK: - Signing

    private func signedGet(_ relative: String) async throws -> Data {
        try await signedRequest(relative, body: nil)
    }

    private func signedRequest(_ relative: String, body: String?) async throws -> Data {
        let url = URL(string: profile.audibleHost.absoluteString + relative)!
        var req = URLRequest(url: url)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = Data(body.utf8)
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let headers = try Self.signatureHeaders(
            method: req.httpMethod!, relativeURL: relative, body: body ?? "",
            adpToken: profile.adpToken, privateKeyPEM: profile.privateKey)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return try await http.send(req).0
    }

    /// The signature covers `METHOD\nURL\nTIME\nBODY\nADP_TOKEN`. The original rounds the time
    /// down to 10 minutes; this is kept for compatibility.
    static func signatureHeaders(
        method: String, relativeURL: String, body: String,
        adpToken: String, privateKeyPEM: String, now: Date = Date()
    ) throws -> [String: String] {
        let rounded = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 600).rounded(.down) * 600)
        let time = DateParsing.xmlString(rounded)
        let data = "\(method)\n\(relativeURL)\n\(time)\n\(body)\n\(adpToken)"
        let sig = try Crypto.rsaSign(data, privateKeyPEM: privateKeyPEM)
        return [
            "x-adp-token": adpToken,
            "x-adp-alg": "SHA256withRSA:1.0",
            "x-adp-signature": "\(sig):\(time)",
        ]
    }
}
