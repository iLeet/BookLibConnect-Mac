import Foundation

public enum DownloadQuality: Int, Codable, Sendable, CaseIterable, Comparable {
    case low, normal, high, extreme

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    /// Name as used in the license request body.
    public var apiName: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .extreme: "Extreme"
        }
    }

    /// The UI only offers Normal and High.
    public var reduced: DownloadQuality {
        switch self {
        case .extreme, .high: .high
        default: .normal
        }
    }
}

public enum InitialSorting: Int, Codable, Sendable, CaseIterable, Identifiable {
    case stateDate, date, authorTitle, authorDate, titleAuthor

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .stateDate: "state, date"
        case .date: "date"
        case .authorTitle: "author, title"
        case .authorDate: "author, date"
        case .titleAuthor: "title, author"
        }
    }
}

/// Order matters: comparisons such as `state < .localLocked` drive the download/decrypt decisions.
public enum ConversionState: Int, Codable, Sendable, Comparable, CaseIterable {
    case unknown, remote, download, licenseGranted, licenseDenied, downloading, downloadError
    case localLocked, unlocking, unlockingFailed, localUnlocked
    case exported, converting, converted, convertedUnknown, conversionError

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    public var label: String {
        switch self {
        case .unknown: "unknown"
        case .remote: "not downloaded"
        case .download: "selected for download"
        case .licenseGranted: "license obtained"
        case .licenseDenied: "license denied"
        case .downloading: "downloading"
        case .downloadError: "download error"
        case .localLocked: "local, locked"
        case .unlocking: "unlocking"
        case .unlockingFailed: "unlocking error"
        case .localUnlocked: "local, unlocked"
        case .exported: "exported"
        case .converting: "converting"
        case .converted: "converted"
        case .convertedUnknown: "converted, not found"
        case .conversionError: "conversion error"
        }
    }
}

public enum DeliveryType: String, Codable, Sendable {
    case singlePartBook = "SinglePartBook"
    case multiPartBook = "MultiPartBook"
    case audioPart = "AudioPart"
    case bookSeries = "BookSeries"
    case periodical = "Periodical"

    public var label: String {
        switch self {
        case .singlePartBook: "Single part book"
        case .multiPartBook: "Multi part book"
        case .audioPart: "Audio part"
        case .bookSeries: "Book series"
        case .periodical: "Periodical"
        }
    }
}

public struct Chapter: Codable, Sendable, Hashable {
    public var title: String
    public var lengthMs: Int
    public var startOffsetMs: Int
    public var children: [Chapter] = []

    public init(title: String, lengthMs: Int, startOffsetMs: Int, children: [Chapter] = []) {
        self.title = title
        self.lengthMs = lengthMs
        self.startOffsetMs = startOffsetMs
        self.children = children
    }

    init(_ json: ChapterJSON) {
        title = json.title ?? ""
        lengthMs = json.length_ms ?? 0
        startOffsetMs = json.start_offset_ms ?? 0
        children = (json.chapters ?? []).map(Chapter.init)
    }

    /// Depth-first, parent before children.
    public var flattened: [Chapter] {
        [Chapter(title: title, lengthMs: lengthMs, startOffsetMs: startOffsetMs)]
            + children.flatMap(\.flattened)
    }
}

public struct ChapterInfo: Codable, Sendable, Hashable {
    public var brandIntroDurationMs: Int = 0
    public var brandOutroDurationMs: Int = 0
    public var runtimeLengthMs: Int = 0
    public var isAccurate: Bool?
    public var chapters: [Chapter] = []

    public init() {}

    init(_ json: ChapterInfoJSON) {
        brandIntroDurationMs = json.brandIntroDurationMs ?? 0
        brandOutroDurationMs = json.brandOutroDurationMs ?? 0
        runtimeLengthMs = json.runtime_length_ms ?? 0
        isAccurate = json.is_accurate
        chapters = (json.chapters ?? []).map(Chapter.init)
    }

    public var flattenedChapters: [Chapter] { chapters.flatMap(\.flattened) }
}

/// Something that can be downloaded and decrypted: a whole book, or one part of a multi-part book.
public struct MediaUnit: Codable, Sendable, Hashable, Identifiable {
    public var id: String { asin }
    public var asin: String
    public var title: String?
    public var partNumber: Int = 0
    public var runtimeSeconds: Int?
    public var fileSizeBytes: Int64?
    public var sampleRate: Int?
    public var bitRate: Int?
    public var downloadQuality: DownloadQuality?
    public var codec: String?
    public var sku: String?
    public var skuLite: String?
    public var licenseKey: String?
    public var licenseIv: String?
    public var chapterInfo: ChapterInfo?
    public var state: ConversionState = .remote
    public var lastUpdate: Date = Date()
    /// Path of the downloaded file without extension.
    public var downloadFileName: String?

    public init(asin: String, title: String? = nil, partNumber: Int = 0) {
        self.asin = asin
        self.title = title
        self.partNumber = partNumber
    }

    public var applicableQuality: DownloadQuality { downloadQuality ?? .extreme }
}

public struct SeriesEntry: Codable, Sendable, Hashable {
    public var asin: String?
    public var title: String?
    public var sequence: String?
    public var sort: Int?
    public var bookNumber: Int = 0
    public var subNumber: Int?

    public var sequenceString: String {
        if let sequence { return sequence }
        return "\(bookNumber)" + (subNumber.map { ".\($0)" } ?? "")
    }
}

public struct Book: Codable, Sendable, Identifiable, Hashable {
    public var id: String { asin }
    public var asin: String
    public var title: String
    public var subtitle: String?
    public var publisherName: String?
    public var publisherSummary: String?
    public var merchandisingSummary: String?
    public var averageRating: Double?
    public var authors: [Person] = []
    public var narrators: [Person] = []
    public var adultProduct: Bool?
    public var purchaseDate: Date?
    public var releaseDate: Date?
    public var language: String?
    public var coverImageURL: String?
    public var coverImageFile: String?
    public var deliveryType: DeliveryType?
    public var unabridged: Bool?
    public var series: [SeriesEntry] = []
    /// Genre ladders, e.g. ["Literature & Fiction", "Classics"].
    public var genres: [[String]] = []
    public var codecs: [String] = []
    public var deleted: Bool = false
    /// Local account the book belongs to.
    public var accountId: Int
    public var region: Region
    public var whole: MediaUnit
    public var parts: [MediaUnit] = []

    // MARK: Derived

    public var author: String? { firstEtAl(authors.compactMap(\.name)) }
    public var narrator: String? { firstEtAl(narrators.compactMap(\.name)) }
    public var allAuthors: String? { authors.isEmpty ? nil : authors.compactMap(\.name).joined(separator: ", ") }
    public var allNarrators: String? { narrators.isEmpty ? nil : narrators.compactMap(\.name).joined(separator: ", ") }

    public var releaseYear: Int? {
        releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    public var hasParts: Bool { !parts.isEmpty }

    /// The units that are actually downloaded, depending on the multi-part setting.
    public func units(multiPart: Bool) -> [MediaUnit] {
        multiPart && hasParts ? parts : [whole]
    }

    public func applicableState(multiPart: Bool) -> ConversionState {
        units(multiPart: multiPart).map(\.state).min() ?? whole.state
    }

    public func applicableQuality(multiPart: Bool) -> DownloadQuality {
        units(multiPart: multiPart).map(\.applicableQuality).min() ?? .extreme
    }

    private func firstEtAl(_ names: [String]) -> String? {
        guard let first = names.first else { return nil }
        return names.count > 1 ? first + " et al." : first
    }
}

extension Book {
    func updating(unit: MediaUnit) -> Book {
        var b = self
        if unit.asin == b.whole.asin {
            b.whole = unit
        } else if let i = b.parts.firstIndex(where: { $0.asin == unit.asin }) {
            b.parts[i] = unit
        }
        return b
    }
}

/// A (book, unit) pair: what the download list rows and the job pipeline operate on.
public struct ConversionRef: Hashable, Sendable, Identifiable {
    public var bookAsin: String
    public var unitAsin: String
    public var id: String { unitAsin }

    public init(bookAsin: String, unitAsin: String) {
        self.bookAsin = bookAsin
        self.unitAsin = unitAsin
    }
}

public struct Account: Codable, Sendable, Identifiable, Hashable {
    public var id: Int
    public var alias: String
    public var audibleId: String
}

public struct ProfileAlias: Codable, Sendable, Hashable {
    public var alias: String
    public var region: Region
    public init(alias: String, region: Region) {
        self.alias = alias
        self.region = region
    }
}
