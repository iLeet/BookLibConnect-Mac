import CommonCrypto
import Foundation

/// Descriptive tags and artwork written into the finished `.m4b` when the source carries none.
public struct M4BMetadata: Sendable {
    public var title: String?
    public var author: String?
    public var narrator: String?
    public var album: String?
    public var genre: String?
    public var year: Int?
    public var comment: String?
    public var coverImage: Data?

    public init(
        title: String? = nil, author: String? = nil, narrator: String? = nil, album: String? = nil,
        genre: String? = nil, year: Int? = nil, comment: String? = nil, coverImage: Data? = nil
    ) {
        self.title = title
        self.author = author
        self.narrator = narrator
        self.album = album
        self.genre = genre
        self.year = year
        self.comment = comment
        self.coverImage = coverImage
    }
}

public struct RemuxResult: Sendable {
    public var channelCount: Int
    public var sampleRate: Int
    public var sampleCount: Int
}

public enum RemuxError: Error, LocalizedError {
    case invalidKey
    case noAudioTrack
    case notEncrypted(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "The license key or IV has the wrong format."
        case .noAudioTrack: "The file contains no audio track."
        case .notEncrypted(let t): "Unexpected audio format '\(t)'; expected an Audible encrypted track."
        case .cancelled: "Cancelled."
        }
    }
}

/// Converts a downloaded Audible `.aaxc` file into a plain `.m4b`.
///
/// AAXC is an MP4 whose audio samples are AES-128-CBC encrypted — each sample on its own, with the
/// same key and IV, and a trailing partial block left in the clear. Decrypting means walking the
/// sample table, decrypting each audio sample in place inside `mdat`, renaming the sample entry from
/// `aavd` to `mp4a` and writing a fresh `ftyp`/`moov`. Everything else (e.g. a chapter text track)
/// is carried over unchanged.
public enum AAXCRemuxer {
    public static func convert(
        input: URL, output: URL, keyHex: String, ivHex: String,
        chapters: ChapterInfo? = nil, metadata: M4BMetadata? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> RemuxResult {
        guard let key = Data(hexString: keyHex), key.count == 16,
              let iv = Data(hexString: ivHex), iv.count == 16
        else { throw RemuxError.invalidKey }

        let file = try Data(contentsOf: input, options: .alwaysMapped)
        let fm = FileManager.default
        let partial = output.appendingPathExtension("part")
        fm.createFile(atPath: partial.path, contents: nil)
        let out = try FileHandle(forWritingTo: partial)
        defer { try? out.close() }

        do {
            let result = try file.withUnsafeBytes { raw in
                try run(
                    file: raw, out: out, key: key, iv: iv, chapters: chapters, metadata: metadata,
                    progress: progress, isCancelled: isCancelled)
            }
            try out.close()
            try? fm.removeItem(at: output)
            try fm.moveItem(at: partial, to: output)
            return result
        } catch {
            try? out.close()
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    private static func run(
        file: UnsafeRawBufferPointer, out: FileHandle, key: Data, iv: Data,
        chapters: ChapterInfo?, metadata: M4BMetadata?,
        progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)?
    ) throws -> RemuxResult {
        let boxes = try scanTopLevel(file)
        guard let moovBox = boxes.first(where: { $0.type == "moov" }) else { throw MP4Error.malformed("no moov box") }
        let mdats = boxes.filter { $0.type == "mdat" }
        guard mdats.count == 1, let mdat = mdats.first else {
            throw MP4Error.unsupported("expected exactly one mdat box")
        }

        let moovBytes = Array(file[moovBox.start..<moovBox.end])
        guard let moov = try MP4Node.parse(moovBytes, range: 0..<moovBytes.count).first, moov.type == "moov" else {
            throw MP4Error.malformed("moov")
        }

        // Locate the audio track and its sample table.
        let traks = moov.children?.filter { $0.type == "trak" } ?? []
        guard let audio = traks.first(where: { $0.handlerType == "soun" }),
              let stbl = audio.path("mdia", "minf", "stbl"),
              let stsd = stbl.child("stsd")
        else { throw RemuxError.noAudioTrack }

        // stsd: version/flags, entry_count, then entries: size, type, ...
        guard stsd.payload.count >= 8 + 8 + 28 else { throw MP4Error.malformed("stsd") }
        let entryType = fourCC(stsd.payload[12..<16])
        guard entryType == "aavd" else { throw RemuxError.notEncrypted(entryType) }
        for (i, b) in "mp4a".utf8.enumerated() { stsd.payload[12 + i] = b }
        let channels = stsd.payload.be16(8 + 8 + 16)
        let sampleRate = stsd.payload.be16(8 + 8 + 24)

        let table = try SampleTable(stbl: stbl)
        let extents = try table.sampleExtents()

        if extents.contains(where: { $0.offset < mdat.payloadStart || $0.offset + $0.size > mdat.end }) {
            throw MP4Error.malformed("audio sample outside of mdat")
        }

        // Optional extras: chapters and tags, only when the source has none.
        let hasChapterTrack = traks.contains { ["text", "sbtl"].contains($0.handlerType ?? "") }
        addExtras(to: moov, chapters: hasChapterTrack ? nil : chapters, metadata: metadata)

        // New layout: ftyp | moov | mdat (header + payload copied verbatim).
        let ftyp = makeFtyp()
        let moovSize = moov.serialized.count
        let newMdatStart = ftyp.count + moovSize
        let delta = newMdatStart - mdat.start
        for trak in traks {
            try trak.path("mdia", "minf", "stbl")?.shiftChunkOffsets(by: delta)
        }
        let newMoov = moov.serialized
        precondition(newMoov.count == moovSize)

        try out.write(contentsOf: ftyp)
        try out.write(contentsOf: newMoov)
        try out.write(contentsOf: Array(file[mdat.start..<mdat.payloadStart]))

        // Stream mdat, decrypting audio samples on the way.
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { k in
            iv.withUnsafeBytes { v in
                CCCryptorCreate(
                    CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                    k.baseAddress, 16, v.baseAddress, &cryptor)
            }
        }
        guard status == kCCSuccess, let cryptor else { throw CryptoError.aes(status) }
        defer { CCCryptorRelease(cryptor) }

        let ivBytes = [UInt8](iv)
        var buffer = [UInt8]()
        buffer.reserveCapacity(4 << 20)
        func flush() throws {
            if !buffer.isEmpty {
                try out.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        var cursor = mdat.payloadStart
        let ordered = extents.enumerated().sorted { $0.element.offset < $1.element.offset }
        let total = Double(mdat.end - mdat.payloadStart)
        var tmp = [UInt8](repeating: 0, count: 1 << 16)

        for (n, (_, e)) in ordered.enumerated() {
            if n & 0x3FF == 0 {
                if isCancelled?() == true { throw RemuxError.cancelled }
                progress?(Double(cursor - mdat.payloadStart) / total)
            }
            if e.offset > cursor {
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: file[cursor..<e.offset]))
                if buffer.count >= 4 << 20 { try flush() }
            }
            let blocks = e.size & ~0xF
            if tmp.count < e.size { tmp = [UInt8](repeating: 0, count: e.size) }
            if blocks > 0 {
                let resetStatus = ivBytes.withUnsafeBytes { CCCryptorReset(cryptor, $0.baseAddress) }
                guard resetStatus == kCCSuccess else { throw CryptoError.aes(resetStatus) }
                var moved = 0
                let st = tmp.withUnsafeMutableBytes { dst in
                    CCCryptorUpdate(
                        cryptor, file.baseAddress! + e.offset, blocks, dst.baseAddress, blocks, &moved)
                }
                guard st == kCCSuccess else { throw CryptoError.aes(st) }
            }
            buffer.append(contentsOf: tmp[0..<blocks])
            if blocks < e.size {
                buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: file[e.offset + blocks..<e.offset + e.size]))
            }
            if buffer.count >= 4 << 20 { try flush() }
            cursor = e.offset + e.size
        }
        if cursor < mdat.end {
            buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: file[cursor..<mdat.end]))
        }
        try flush()
        progress?(1)

        return RemuxResult(channelCount: channels, sampleRate: sampleRate, sampleCount: extents.count)
    }

    private static func makeFtyp() -> [UInt8] {
        var body: [UInt8] = []
        body.appendFourCC("M4B ")
        body.appendBE32(0)
        for brand in ["M4B ", "mp42", "isom"] { body.appendFourCC(brand) }
        return MP4Node(type: "ftyp", payload: body).serialized
    }

    // MARK: - Chapters and tags

    private static func addExtras(to moov: MP4Node, chapters: ChapterInfo?, metadata: M4BMetadata?) {
        var extras: [MP4Node] = []

        if let chpl = chaplBox(chapters) { extras.append(chpl) }

        // Tags: keep whatever the source carries; only add ours when it has no title tag.
        let udta = moov.child("udta")
        if let existing = udta?.child("meta"), hasTitleTag(existing) {
            // keep as is
        } else if let meta = metaBox(metadata) {
            udta?.children?.removeAll { $0.type == "meta" }
            extras.append(meta)
        }

        guard !extras.isEmpty else { return }
        if let udta {
            udta.children?.append(contentsOf: extras)
        } else {
            moov.children?.append(MP4Node(type: "udta", children: extras))
        }
    }

    /// True when the `meta` box holds an `ilst` with a title (`©nam`) item.
    private static func hasTitleTag(_ meta: MP4Node) -> Bool {
        guard meta.payload.count > 4,
              let kids = try? MP4Node.parse(meta.payload, range: 4..<meta.payload.count),
              let ilst = kids.first(where: { $0.type == "ilst" }),
              let items = try? MP4Node.parse(ilst.payload, range: 0..<ilst.payload.count)
        else { return false }
        return items.contains { $0.type == "\u{A9}nam" }
    }

    /// Nero-style chapter list (`chpl`), understood by Apple Books, VLC, ffmpeg and most players.
    static func chaplBox(_ info: ChapterInfo?) -> MP4Node? {
        guard let info else { return nil }
        let list = info.flattenedChapters.filter { !$0.title.isEmpty }
        guard !list.isEmpty else { return nil }
        var body: [UInt8] = [1, 0, 0, 0]  // version 1, flags 0
        body.appendBE32(0)  // reserved
        let capped = list.prefix(255)
        body.append(UInt8(capped.count))
        for ch in capped {
            body.appendBE64(UInt64(max(0, ch.startOffsetMs)) * 10_000)  // 100 ns units
            let title = Array(ch.title.utf8.prefix(255))
            body.append(UInt8(title.count))
            body.append(contentsOf: title)
        }
        return MP4Node(type: "chpl", payload: body)
    }

    static func metaBox(_ m: M4BMetadata?) -> MP4Node? {
        guard let m else { return nil }
        var items: [MP4Node] = []

        func text(_ type: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            items.append(MP4Node(type: type, children: [dataBox(flag: 1, Array(value.utf8))]))
        }

        text("\u{A9}nam", m.title)
        text("\u{A9}ART", m.author)
        text("\u{A9}alb", m.album ?? m.title)
        text("\u{A9}wrt", m.narrator)
        text("\u{A9}gen", m.genre)
        text("\u{A9}day", m.year.map(String.init))
        text("desc", m.comment.map { String($0.prefix(255)) })
        text("\u{A9}cmt", m.comment)
        if let cover = m.coverImage, !cover.isEmpty {
            let isPNG = cover.starts(with: [0x89, 0x50, 0x4E, 0x47])
            items.append(MP4Node(type: "covr", children: [dataBox(flag: isPNG ? 14 : 13, [UInt8](cover))]))
        }
        guard !items.isEmpty else { return nil }

        var hdlr: [UInt8] = [0, 0, 0, 0]
        hdlr.appendBE32(0)
        hdlr.appendFourCC("mdir")
        hdlr.append(contentsOf: "appl".utf8)
        hdlr.appendBE32(0)
        hdlr.appendBE32(0)
        hdlr.append(0)

        let meta = MP4Node(type: "meta", payload: [])
        // `meta` is a full box: 4 bytes version/flags followed by its children. Its payload is
        // pre-serialised because the tree treats it as a leaf.
        var payload: [UInt8] = [0, 0, 0, 0]
        payload.append(contentsOf: MP4Node(type: "hdlr", payload: hdlr).serialized)
        payload.append(contentsOf: MP4Node(type: "ilst", children: items).serialized)
        meta.payload = payload
        return meta
    }

    private static func dataBox(flag: Int, _ bytes: [UInt8]) -> MP4Node {
        var body: [UInt8] = [0, 0, 0, UInt8(flag)]
        body.appendBE32(0)  // locale
        body.append(contentsOf: bytes)
        return MP4Node(type: "data", payload: body)
    }
}
