import Foundation
import Observation

/// Local book database: books, parts, conversion state and accounts. Persisted as JSON.
@MainActor
@Observable
public final class LibraryStore {
    private struct Snapshot: Codable {
        var version = 1
        var books: [Book] = []
        var accounts: [Account] = []
    }

    public private(set) var books: [Book] = []
    public private(set) var accounts: [Account] = []

    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored public let coverDirectory: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("Library.json")
        coverDirectory = directory.appendingPathComponent("Covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: coverDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? AudibleJSON.snapshotDecoder().decode(Snapshot.self, from: data)
        else { return }
        books = snap.books
        accounts = snap.accounts
        reindex()
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: books.enumerated().map { ($1.asin, $0) })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snap = Snapshot(books: books, accounts: accounts)
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(snap, to: url)
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        Self.write(Snapshot(books: books, accounts: accounts), to: fileURL)
    }

    private nonisolated static func write(_ snap: Snapshot, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try AudibleJSON.snapshotEncoder().encode(snap)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Library save failed: \(error)")
        }
    }

    // MARK: - Accounts

    public func account(forAudibleId audibleId: String) -> Account? {
        accounts.first { $0.audibleId == audibleId }
    }

    public func account(withAlias alias: String) -> Account? {
        accounts.first { $0.alias == alias }
    }

    public func account(id: Int) -> Account? { accounts.first { $0.id == id } }

    @discardableResult
    public func addAccount(audibleId: String, alias: String) -> Account {
        let acc = Account(id: (accounts.map(\.id).max() ?? 0) + 1, alias: alias, audibleId: audibleId)
        accounts.append(acc)
        scheduleSave()
        return acc
    }

    public func setAlias(_ alias: String, forAccount id: Int) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].alias = alias
        scheduleSave()
    }

    public func removeAccount(audibleId: String) {
        accounts.removeAll { $0.audibleId == audibleId }
        scheduleSave()
    }

    // MARK: - Lookup

    public func book(_ asin: String) -> Book? {
        index[asin].map { books[$0] }
    }

    public func books(accountId: Int, region: Region) -> [Book] {
        books.filter { $0.accountId == accountId && $0.region == region }
    }

    public func unit(for ref: ConversionRef) -> MediaUnit? {
        guard let b = book(ref.bookAsin) else { return nil }
        if b.whole.asin == ref.unitAsin { return b.whole }
        return b.parts.first { $0.asin == ref.unitAsin }
    }

    public func refs(for book: Book, multiPart: Bool) -> [ConversionRef] {
        book.units(multiPart: multiPart).map { ConversionRef(bookAsin: book.asin, unitAsin: $0.asin) }
    }

    /// Re-read a unit and write a modified copy back.
    public func mutate(_ ref: ConversionRef, _ body: (inout MediaUnit) -> Void) {
        guard let i = index[ref.bookAsin] else { return }
        var unit: MediaUnit
        if books[i].whole.asin == ref.unitAsin {
            unit = books[i].whole
            body(&unit)
            books[i].whole = unit
        } else if let j = books[i].parts.firstIndex(where: { $0.asin == ref.unitAsin }) {
            unit = books[i].parts[j]
            body(&unit)
            books[i].parts[j] = unit
        } else {
            return
        }
        scheduleSave()
    }

    public func mutateBook(_ asin: String, _ body: (inout Book) -> Void) {
        guard let i = index[asin] else { return }
        body(&books[i])
        scheduleSave()
    }

    public func setState(_ ref: ConversionRef, _ state: ConversionState) {
        mutate(ref) {
            $0.state = state
            $0.lastUpdate = Date()
        }
    }

    // MARK: - Library merge

    /// Latest purchase date known for the profile, used for incremental library updates.
    public func sinceLatestPurchaseDate(accountId: Int, region: Region, resync: Bool) -> Date {
        let epoch = Date(timeIntervalSince1970: 0)
        if resync { return epoch }
        let latest = books
            .filter { $0.accountId == accountId && $0.region == region }
            .compactMap(\.purchaseDate)
            .max()
        return latest.map { $0.addingTimeInterval(0.001) } ?? epoch
    }

    /// Port of `addRemBooks`: add new products, optionally undelete / mark removed ones.
    public func merge(products: [Product], accountId: Int, region: Region, resync: Bool) {
        for product in products {
            guard let asin = product.asin else { continue }
            if let i = index[asin] {
                guard resync, books[i].deleted else { continue }
                books[i].deleted = false
                books[i].accountId = accountId
                books[i].region = region
                if books[i].whole.state < .localLocked { books[i].whole.state = .remote }
                for j in books[i].parts.indices {
                    if books[i].parts[j].state < .localLocked { books[i].parts[j].state = .remote }
                }
                continue
            }
            books.append(Self.makeBook(from: product, accountId: accountId, region: region))
            index[asin] = books.count - 1
        }

        if resync {
            let current = Set(products.compactMap(\.asin))
            for i in books.indices
            where !current.contains(books[i].asin)
                && books[i].accountId == accountId && books[i].region == region
                && !books[i].deleted {
                books[i].deleted = true
                if books[i].whole.state < .localLocked { books[i].whole.state = .unknown }
                for j in books[i].parts.indices where books[i].parts[j].state < .localLocked {
                    books[i].parts[j].state = .unknown
                }
            }
        }
        scheduleSave()
    }

    /// Refresh meta data of a book from a catalog product (used to fill gaps).
    public func updateMeta(asin: String, from product: Product) {
        mutateBook(asin) { b in
            if let v = product.publisher_name { b.publisherName = v }
            if let v = product.publisher_summary { b.publisherSummary = v }
            if let v = product.merchandising_summary { b.merchandisingSummary = v }
            if let v = product.rating?.overall_distribution?.average_rating { b.averageRating = v }
            if let v = product.language { b.language = v }
            if let v = product.release_date ?? product.issue_date { b.releaseDate = v }
            if let v = product.runtime_length_min, b.whole.runtimeSeconds == nil {
                b.whole.runtimeSeconds = v * 60
            }
        }
    }

    private static let seriesRegex = try! NSRegularExpression(pattern: #"(\d+)(\.(\d+))?"#)

    static func makeBook(from product: Product, accountId: Int, region: Region) -> Book {
        let asin = product.asin ?? ""
        var whole = MediaUnit(asin: asin, title: product.title)
        whole.runtimeSeconds = product.runtime_length_min.map { $0 * 60 }
        whole.sku = product.sku
        whole.skuLite = product.sku_lite

        var book = Book(
            asin: asin, title: product.title ?? "", accountId: accountId, region: region, whole: whole)
        book.subtitle = product.subtitle
        book.publisherName = product.publisher_name
        book.publisherSummary = product.publisher_summary
        book.merchandisingSummary = product.merchandising_summary
        book.averageRating = product.rating?.overall_distribution?.average_rating
        book.adultProduct = product.is_adult_product
        book.purchaseDate = product.purchase_date
        book.releaseDate = product.release_date ?? product.issue_date
        book.language = product.language
        book.coverImageURL = product.product_images?["500"]
        book.deliveryType = product.content_delivery_type.flatMap(DeliveryType.init(rawValue:))
        if let fmt = product.format_type, !fmt.isEmpty { book.unabridged = fmt == "unabridged" }

        book.authors = (product.authors ?? []).filter { $0.name != nil }
        book.narrators = (product.narrators ?? []).filter { $0.name != nil }

        let relations = product.relationships ?? []

        // components = parts
        for rel in relations where rel.relationship_to_product == "child" && rel.relationship_type == "component" {
            guard let partAsin = rel.asin else { continue }
            var part = MediaUnit(asin: partAsin, title: rel.title, partNumber: Int(rel.sort ?? "") ?? 0)
            part.sku = rel.sku
            part.skuLite = rel.sku_lite
            book.parts.append(part)
        }

        // series
        for rel in relations where rel.relationship_to_product == "parent" && rel.relationship_type == "series" {
            var entry = SeriesEntry(asin: rel.asin, title: rel.title, sequence: rel.sequence, sort: Int(rel.sort ?? ""))
            if let seq = rel.sequence {
                let ns = seq as NSString
                if let m = seriesRegex.firstMatch(in: seq, range: NSRange(location: 0, length: ns.length)) {
                    entry.bookNumber = Int(ns.substring(with: m.range(at: 1))) ?? 0
                    if m.range(at: 3).location != NSNotFound {
                        entry.subNumber = Int(ns.substring(with: m.range(at: 3)))
                    }
                }
            }
            book.series.append(entry)
        }

        // genres
        for cat in product.category_ladders ?? [] where cat.root == "Genres" {
            let names = (cat.ladder ?? []).compactMap(\.name)
            if !names.isEmpty { book.genres.append(names) }
        }

        book.codecs = (product.available_codecs ?? []).compactMap(\.name)
        return book
    }

    // MARK: - Licensing

    /// Port of `UpdateLicenseAndChapters`. Returns the audio quality encoded in the codec name.
    @discardableResult
    public func applyLicense(
        _ license: ContentLicense, voucher: Voucher, to ref: ConversionRef,
        quality: DownloadQuality, downloadDirectory: String
    ) -> AudioQuality? {
        guard let book = book(ref.bookAsin), var unit = unit(for: ref) else { return nil }

        unit.licenseKey = voucher.key
        unit.licenseIv = voucher.iv
        unit.downloadQuality = quality

        let format = license.content_metadata?.content_reference?.content_format?.lowercased()
        var aq: AudioQuality?
        var name = String(Self.prune(unit.title ?? book.title).prefix(20))
        name += "_\(unit.asin)_LC"
        if let format {
            unit.codec = format
            aq = AudioQuality(codec: format)
            if let aq {
                unit.bitRate = aq.bitRate
                unit.sampleRate = aq.sampleRate
                if let b = aq.bitRate { name += "_\(b)" }
                if let s = aq.sampleRate { name += "_\(s)" }
            }
        }
        unit.downloadFileName = (downloadDirectory as NSString).appendingPathComponent(name)

        unit.fileSizeBytes = license.content_metadata?.content_reference?.content_size_in_bytes
        if let secs = license.content_metadata?.chapter_info?.runtime_length_sec {
            unit.runtimeSeconds = secs
        }
        if let ci = license.content_metadata?.chapter_info {
            unit.chapterInfo = ChapterInfo(ci)
        }
        unit.state = .licenseGranted
        unit.lastUpdate = Date()

        mutate(ref) { $0 = unit }
        return aq
    }

    public func saveFileNameSuffix(_ ref: ConversionRef, suffix: String) {
        mutate(ref) { $0.downloadFileName = ($0.downloadFileName ?? "") + suffix }
    }

    // MARK: - File checks

    public struct StateChange: Sendable {
        public var ref: ConversionRef
        public var newState: ConversionState
    }

    /// Port of `CheckUpdateFilesAndState`: find conversions whose files have vanished.
    public func findStateChanges(downloadDirectory: String?, exportDirectory: String?) -> [StateChange] {
        var changes: [StateChange] = []
        let fm = FileManager.default

        func exists(_ stub: String?, _ ext: String) -> Bool {
            guard let stub else { return false }
            return fm.fileExists(atPath: stub + ext)
        }

        func relocated(_ unit: MediaUnit, _ ext: String) -> Bool {
            guard let dir = downloadDirectory, let stub = unit.downloadFileName else { return false }
            let alt = (dir as NSString).appendingPathComponent((stub as NSString).lastPathComponent)
            return fm.fileExists(atPath: alt + ext)
        }

        func check(_ unit: MediaUnit, ref: ConversionRef) {
            switch unit.state {
            case .localLocked:
                if !(exists(unit.downloadFileName, FileExt.encrypted) || relocated(unit, FileExt.encrypted)) {
                    changes.append(.init(ref: ref, newState: .remote))
                }
            case .localUnlocked:
                let ok = exists(unit.downloadFileName, FileExt.decrypted)
                    || relocated(unit, FileExt.decrypted)
                if !ok {
                    if exists(unit.downloadFileName, FileExt.encrypted) || relocated(unit, FileExt.encrypted) {
                        changes.append(.init(ref: ref, newState: .localLocked))
                    } else {
                        changes.append(.init(ref: ref, newState: .remote))
                    }
                }
            case .exported:
                guard let stub = unit.downloadFileName else { break }
                let name = (stub as NSString).lastPathComponent
                let exportOK = exportDirectory.map {
                    fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(name) + FileExt.exported)
                } ?? false
                if !exportOK {
                    if exists(stub, FileExt.decrypted) || relocated(unit, FileExt.decrypted) {
                        changes.append(.init(ref: ref, newState: .localUnlocked))
                    } else {
                        changes.append(.init(ref: ref, newState: .convertedUnknown))
                    }
                }
            default: break
            }
        }

        for book in books where !book.deleted {
            check(book.whole, ref: .init(bookAsin: book.asin, unitAsin: book.whole.asin))
            for p in book.parts { check(p, ref: .init(bookAsin: book.asin, unitAsin: p.asin)) }
        }
        return changes
    }

    public func apply(_ changes: [StateChange]) {
        for c in changes { setState(c.ref, c.newState) }
    }

    // MARK: - Covers

    public func coverURL(for book: Book) -> URL? {
        guard let f = book.coverImageFile else { return nil }
        return coverDirectory.appendingPathComponent(f)
    }

    public func setCoverFile(_ file: String, forBook asin: String) {
        mutateBook(asin) { $0.coverImageFile = file }
    }

    // MARK: - Helpers

    nonisolated static func prune(_ s: String) -> String {
        let invalid = Set("/\\:*?\"<>|\0")
        var out = s.filter { !invalid.contains($0) }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: ".")).trimmingCharacters(in: .whitespaces)
        return out
    }
}

public enum FileExt {
    public static let encrypted = ".aaxc"
    public static let decrypted = ".m4b"
    public static let exported = ".aax"
}

public struct AudioQuality: Sendable, Hashable {
    public var sampleRate: Int?
    public var bitRate: Int?

    /// Parses codec names such as `aax_22_64` / `aax_44_128`. Other formats carry no quality.
    public init?(codec: String) {
        let parts = codec.split(separator: "_")
        guard codec.hasPrefix("aax"), parts.count >= 3,
              let sr = Int(parts[1]), let br = Int(parts[2])
        else { return nil }
        sampleRate = sr * 22050 / 22
        bitRate = br
    }
}

extension AudibleJSON {
    static func snapshotEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DateParsing.xmlString(date))
        }
        return e
    }

    static func snapshotDecoder() -> JSONDecoder {
        decoder()
    }
}
