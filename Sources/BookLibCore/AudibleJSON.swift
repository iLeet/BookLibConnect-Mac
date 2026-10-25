import Foundation

// Wire formats of the Audible API. Only the fields the app uses are declared;
// everything is optional so that server-side changes degrade gracefully.

public enum AudibleJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = DateParsing.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognised date \(s)")
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DateParsing.xmlString(date))
        }
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

public enum DateParsing {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    nonisolated(unsafe) private static let dateOnly: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    public static func parse(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s) ?? dateOnly.date(from: s)
    }

    /// Mirrors `XmlConvert.ToString(dt, Utc)`: fractional seconds only when present.
    public static func xmlString(_ date: Date) -> String {
        let ms = (date.timeIntervalSince1970 * 1000).rounded() / 1000
        if ms.truncatingRemainder(dividingBy: 1) == 0 {
            return plain.string(from: Date(timeIntervalSince1970: ms))
        }
        var s = fractional.string(from: Date(timeIntervalSince1970: ms))
        // trim trailing zeros of the fraction: ".120Z" -> ".12Z"
        if let dot = s.firstIndex(of: "."), s.hasSuffix("Z") {
            var frac = String(s[s.index(after: dot)..<s.index(before: s.endIndex)])
            while frac.hasSuffix("0") { frac.removeLast() }
            s = String(s[..<dot]) + (frac.isEmpty ? "" : "." + frac) + "Z"
        }
        return s
    }
}

// MARK: - Library / catalog

public struct LibraryResponse: Codable, Sendable {
    public var items: [Product]?
}

public struct ProductResponse: Codable, Sendable {
    public var product: Product?
}

public struct SimsBySeriesResponse: Codable, Sendable {
    public var similar_products: [Product]?
}

public struct Product: Codable, Sendable {
    public var asin: String?
    public var title: String?
    public var subtitle: String?
    public var authors: [Person]?
    public var narrators: [Person]?
    public var publisher_name: String?
    public var publisher_summary: String?
    public var merchandising_summary: String?
    public var rating: Rating?
    public var runtime_length_min: Int?
    public var is_adult_product: Bool?
    public var is_listenable: Bool?
    public var has_children: Bool?
    public var purchase_date: Date?
    public var release_date: Date?
    public var issue_date: Date?
    public var language: String?
    public var product_images: [String: String]?
    public var sku: String?
    public var sku_lite: String?
    public var content_delivery_type: String?
    public var format_type: String?
    public var relationships: [Relationship]?
    public var series: [SeriesRef]?
    public var category_ladders: [ProductCategory]?
    public var available_codecs: [CodecRef]?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case asin, title, subtitle, authors, narrators, publisher_name, publisher_summary
        case merchandising_summary, rating, runtime_length_min, is_adult_product, is_listenable
        case has_children, purchase_date, release_date, issue_date, language, product_images
        case sku, sku_lite, content_delivery_type, format_type, relationships, series
        case category_ladders, available_codecs
    }

    // Lenient decoding: a field of unexpected shape is dropped rather than failing the page.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asin = try? c.decodeIfPresent(String.self, forKey: .asin)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        authors = try? c.decodeIfPresent([Person].self, forKey: .authors)
        narrators = try? c.decodeIfPresent([Person].self, forKey: .narrators)
        publisher_name = try? c.decodeIfPresent(String.self, forKey: .publisher_name)
        publisher_summary = try? c.decodeIfPresent(String.self, forKey: .publisher_summary)
        merchandising_summary = try? c.decodeIfPresent(String.self, forKey: .merchandising_summary)
        rating = try? c.decodeIfPresent(Rating.self, forKey: .rating)
        runtime_length_min = try? c.decodeIfPresent(Int.self, forKey: .runtime_length_min)
        is_adult_product = try? c.decodeIfPresent(Bool.self, forKey: .is_adult_product)
        is_listenable = try? c.decodeIfPresent(Bool.self, forKey: .is_listenable)
        has_children = try? c.decodeIfPresent(Bool.self, forKey: .has_children)
        purchase_date = try? c.decodeIfPresent(Date.self, forKey: .purchase_date)
        release_date = try? c.decodeIfPresent(Date.self, forKey: .release_date)
        issue_date = try? c.decodeIfPresent(Date.self, forKey: .issue_date)
        language = try? c.decodeIfPresent(String.self, forKey: .language)
        product_images = try? c.decodeIfPresent([String: String].self, forKey: .product_images)
        sku = try? c.decodeIfPresent(String.self, forKey: .sku)
        sku_lite = try? c.decodeIfPresent(String.self, forKey: .sku_lite)
        content_delivery_type = try? c.decodeIfPresent(String.self, forKey: .content_delivery_type)
        format_type = try? c.decodeIfPresent(String.self, forKey: .format_type)
        relationships = try? c.decodeIfPresent([Relationship].self, forKey: .relationships)
        series = try? c.decodeIfPresent([SeriesRef].self, forKey: .series)
        category_ladders = try? c.decodeIfPresent([ProductCategory].self, forKey: .category_ladders)
        available_codecs = try? c.decodeIfPresent([CodecRef].self, forKey: .available_codecs)
    }
}

public struct Person: Codable, Sendable, Hashable {
    public var asin: String?
    public var name: String?
    public init(asin: String? = nil, name: String? = nil) {
        self.asin = asin
        self.name = name
    }
}

public struct Rating: Codable, Sendable {
    public var overall_distribution: Distribution?
}

public struct Distribution: Codable, Sendable {
    public var average_rating: Double?
}

public struct Relationship: Codable, Sendable {
    public var asin: String?
    public var content_delivery_type: String?
    public var relationship_to_product: String?
    public var relationship_type: String?
    public var sequence: String?
    public var sku: String?
    public var sku_lite: String?
    public var sort: String?
    public var title: String?
    public var url: String?

    public init(
        asin: String? = nil, relationship_to_product: String? = nil, relationship_type: String? = nil,
        sequence: String? = nil, sort: String? = nil, title: String? = nil
    ) {
        self.asin = asin
        self.relationship_to_product = relationship_to_product
        self.relationship_type = relationship_type
        self.sequence = sequence
        self.sort = sort
        self.title = title
    }
}

public struct SeriesRef: Codable, Sendable {
    public var asin: String?
    public var sequence: String?
    public var title: String?
    public var url: String?
}

public struct ProductCategory: Codable, Sendable {
    public var ladder: [LadderRung]?
    public var root: String?

    public init(ladder: [LadderRung]? = nil, root: String? = nil) {
        self.ladder = ladder
        self.root = root
    }
}

public struct LadderRung: Codable, Sendable {
    public var id: String?
    public var name: String?

    public init(id: String? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }
}

public struct CodecRef: Codable, Sendable {
    public var enhanced_codec: String?
    public var format: String?
    public var name: String?
}

// MARK: - Licensing

public struct LicenseResponse: Codable, Sendable {
    public var content_license: ContentLicense?
}

public struct ContentLicense: Codable, Sendable {
    public var acr: String?
    public var asin: String?
    public var content_metadata: ContentMetadata?
    public var drm_type: String?
    public var license_id: String?
    public var license_response: String?
    public var message: String?
    public var request_id: String?
    public var status_code: String?
    public var voucher_id: String?
}

public struct MetadataContainer: Codable, Sendable {
    public var content_metadata: ContentMetadata?
}

public struct ContentMetadata: Codable, Sendable {
    public var chapter_info: ChapterInfoJSON?
    public var content_reference: ContentReference?
    public var content_url: ContentURL?
}

public struct ChapterInfoJSON: Codable, Sendable {
    public var brandIntroDurationMs: Int?
    public var brandOutroDurationMs: Int?
    public var chapters: [ChapterJSON]?
    public var is_accurate: Bool?
    public var runtime_length_ms: Int?
    public var runtime_length_sec: Int?
}

public struct ChapterJSON: Codable, Sendable {
    public var length_ms: Int?
    public var start_offset_ms: Int?
    public var start_offset_sec: Int?
    public var title: String?
    public var chapters: [ChapterJSON]?
}

public struct ContentReference: Codable, Sendable {
    public var acr: String?
    public var asin: String?
    public var content_format: String?
    public var content_size_in_bytes: Int64?
    public var file_version: String?
    public var marketplace: String?
    public var sku: String?
    public var tempo: String?
    public var version: String?
}

public struct ContentURL: Codable, Sendable {
    public var offline_url: String?
}

public struct Voucher: Codable, Sendable {
    public var key: String?
    public var iv: String?
}

// MARK: - Registration

public struct RegistrationResponse: Codable, Sendable {
    public var response: RegistrationEnvelope?
}

public struct RegistrationEnvelope: Codable, Sendable {
    public var success: RegistrationSuccess?
}

public struct RegistrationSuccess: Codable, Sendable {
    public var extensions: RegistrationExtensions?
    public var tokens: RegistrationTokens?
}

public struct RegistrationExtensions: Codable, Sendable {
    public var device_info: DeviceInfoJSON?
    public var customer_info: CustomerInfoJSON?
}

public struct DeviceInfoJSON: Codable, Sendable {
    public var device_name: String?
    public var device_serial_number: String?
    public var device_type: String?
}

public struct CustomerInfoJSON: Codable, Sendable {
    public var user_id: String?
    public var name: String?
    public var given_name: String?
}

public struct RegistrationTokens: Codable, Sendable {
    public var website_cookies: [WebsiteCookie]?
    public var store_authentication_cookie: StoreAuthCookie?
    public var mac_dms: MacDMS?
    public var bearer: Bearer?
}

public struct WebsiteCookie: Codable, Sendable {
    public var Name: String?
    public var Value: String?
}

public struct StoreAuthCookie: Codable, Sendable {
    public var cookie: String?
}

public struct MacDMS: Codable, Sendable {
    public var device_private_key: String?
    public var adp_token: String?
}

public struct Bearer: Codable, Sendable {
    public var access_token: String?
    public var refresh_token: String?
    public var expires_in: String?
}
