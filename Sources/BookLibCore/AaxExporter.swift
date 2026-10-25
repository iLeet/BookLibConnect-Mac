import Foundation

/// Exports finished books for AAX Audio Converter: the `.m4b` copied as `.aax`, plus the JSON
/// side files that tool reads (chapters, product and series info).
public struct AaxExporter: Sendable {
    public let exportDirectory: URL
    public let multiPart: Bool

    public init(exportDirectory: URL, multiPart: Bool) {
        self.exportDirectory = exportDirectory
        self.multiPart = multiPart
    }

    private struct Accumulated { var chapters: [[(title: String, length: Int)]] = [] }

    /// Exports a book. `onUnit` is called as each unit starts/finishes; `progress` reports 0...1 of the copy.
    @MainActor
    public func export(
        book: Book, store: LibraryStore,
        progress: @escaping @Sendable (ConversionRef, Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async {
        var accu = Accumulated()
        var skipSeries = false
        let units = book.units(multiPart: multiPart)
        for unit in units {
            let ref = ConversionRef(bookAsin: book.asin, unitAsin: unit.asin)
            guard let current = store.unit(for: ref) else { continue }
            store.setState(ref, .converting)

            let ok = await copyFile(unit: current, ref: ref, progress: progress, isCancelled: isCancelled)
            guard ok else {
                store.setState(ref, .conversionError)
                continue
            }
            do {
                try exportChapters(book: book, unit: current, accu: &accu)
                try exportProduct(book: book, unit: current)
                if !skipSeries { try exportSeries(book: book, allBooks: store.books) }
            } catch {
                NSLog("Export of side files failed: \(error)")
            }
            skipSeries = true
            store.setState(ref, .exported)
        }
    }

    private func copyFile(
        unit: MediaUnit, ref: ConversionRef,
        progress: @escaping @Sendable (ConversionRef, Double) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> Bool {
        guard let stub = unit.downloadFileName else { return false }
        let source = URL(fileURLWithPath: stub + FileExt.decrypted)
        let dest = exportDirectory.appendingPathComponent(
            (stub as NSString).lastPathComponent + FileExt.exported)
        guard FileManager.default.fileExists(atPath: source.path) else { return false }
        return await Task.detached(priority: .utility) {
            Self.copy(from: source, to: dest, progress: { progress(ref, $0) }, isCancelled: isCancelled)
        }.value
    }

    static func copy(
        from source: URL, to dest: URL, progress: (Double) -> Void, isCancelled: () -> Bool
    ) -> Bool {
        let fm = FileManager.default
        do {
            let size = (try fm.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            try? fm.removeItem(at: dest)
            fm.createFile(atPath: dest.path, contents: nil)
            let src = try FileHandle(forReadingFrom: source)
            let dst = try FileHandle(forWritingTo: dest)
            defer {
                try? src.close()
                try? dst.close()
            }
            var done: Int64 = 0
            while true {
                if isCancelled() {
                    try? fm.removeItem(at: dest)
                    return false
                }
                guard let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try dst.write(contentsOf: chunk)
                done += Int64(chunk.count)
                if size > 0 { progress(Double(done) / Double(size)) }
            }
            progress(1)
            return true
        } catch {
            NSLog("Export copy failed: \(error)")
            try? fm.removeItem(at: dest)
            return false
        }
    }

    // MARK: - Side files

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try AudibleJSON.encoder().encode(value)
        try data.write(to: exportDirectory.appendingPathComponent(name), options: .atomic)
    }

    private func exportChapters(book: Book, unit: MediaUnit, accu: inout Accumulated) throws {
        guard let info = unit.chapterInfo else { return }

        var ref = ContentReference()
        ref.asin = unit.asin
        ref.content_size_in_bytes = unit.fileSizeBytes ?? 0
        ref.sku = unit.sku

        var ci = ChapterInfoJSON()
        ci.brandIntroDurationMs = info.brandIntroDurationMs
        ci.brandOutroDurationMs = info.brandOutroDurationMs
        ci.is_accurate = info.isAccurate ?? false
        ci.runtime_length_ms = info.runtimeLengthMs
        ci.runtime_length_sec = info.runtimeLengthMs / 1000

        // Per nesting level, remember what earlier parts already contained so that repeated
        // intro chapters can be skipped (same title and nearly the same short length).
        var levels: [[(String, Int)]] = []
        var flat: [(chapter: Chapter, level: Int)] = []
        func walk(_ chapters: [Chapter], level: Int) {
            for ch in chapters {
                flat.append((ch, level))
                while levels.count <= level { levels.append([]) }
                levels[level].append((ch.title, ch.lengthMs))
                walk(ch.children, level: level + 1)
            }
        }
        walk(info.chapters, level: 0)

        var out: [ChapterJSON] = []
        for (ch, _) in flat {
            if out.isEmpty && skipChapter(ch, accu: accu) { continue }
            var j = ChapterJSON()
            j.length_ms = ch.lengthMs
            j.start_offset_ms = ch.startOffsetMs
            j.start_offset_sec = ch.startOffsetMs / 1000
            j.title = ch.title
            out.append(j)
        }
        if !out.isEmpty { ci.chapters = out }

        var meta = ContentMetadata()
        meta.chapter_info = ci
        meta.content_reference = ref
        try write(MetadataContainer(content_metadata: meta), name: "content_metadata_\(unit.asin).json")

        for (i, level) in levels.enumerated() {
            while accu.chapters.count <= i { accu.chapters.append([]) }
            accu.chapters[i].append(contentsOf: level.map { (title: $0.0, length: $0.1) })
        }
    }

    private func skipChapter(_ ch: Chapter, accu: Accumulated) -> Bool {
        guard accu.chapters.count >= 2 else { return false }
        for level in accu.chapters.dropLast() {
            if level.contains(where: { $0.title == ch.title && abs($0.length - ch.lengthMs) < 1500 && ch.lengthMs < 25000 }) {
                return true
            }
        }
        return false
    }

    private func exportProduct(book: Book, unit: MediaUnit) throws {
        try write(ProductResponse(product: makeProduct(book: book, unit: unit)), name: "\(unit.asin).json")
    }

    private func exportSeries(book: Book, allBooks: [Book]) throws {
        for entry in book.series {
            guard let seriesAsin = entry.asin else { continue }
            // every known member of the series, in series order
            var members: [(Book, SeriesEntry)] = allBooks.compactMap { b in
                b.series.first { $0.asin == seriesAsin }.map { (b, $0) }
            }
            if members.allSatisfy({ $0.1.sort != nil }) {
                members.sort { ($0.1.sort ?? 0) < ($1.1.sort ?? 0) }
            } else if members.allSatisfy({ $0.1.bookNumber != 0 }) {
                members.sort { ($0.1.bookNumber, $0.1.subNumber ?? 0) < ($1.1.bookNumber, $1.1.subNumber ?? 0) }
            }
            let products = members.map { makeProduct(book: $0.0, unit: $0.0.whole) }
            try write(
                SimsBySeriesResponse(similar_products: products),
                name: "series_titles_\(seriesAsin).json")
        }
    }

    private func makeProduct(book: Book, unit: MediaUnit) -> Product {
        var p = Product()
        p.asin = unit.asin
        p.title = unit.title ?? book.title
        p.sku = unit.sku
        p.sku_lite = unit.skuLite
        p.is_listenable = true
        p.runtime_length_min = unit.runtimeSeconds.map { $0 / 60 }
        p.has_children = unit.asin == book.asin && book.hasParts
        p.is_adult_product = book.adultProduct ?? false
        if !book.authors.isEmpty { p.authors = book.authors }
        if !book.series.isEmpty {
            p.series = book.series.map { SeriesRef(asin: $0.asin, sequence: $0.sequenceString, title: $0.title) }
        }
        return p
    }
}
