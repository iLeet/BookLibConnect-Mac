import Foundation

// A small ISO-BMFF toolkit: just enough to rewrite the `moov` box of an Audible file.

enum MP4Error: Error, LocalizedError {
    case malformed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let m): "Malformed MP4 file: \(m)"
        case .unsupported(let m): "Unsupported MP4 file: \(m)"
        }
    }
}

extension Array where Element == UInt8 {
    func be16(_ o: Int) -> Int { Int(self[o]) << 8 | Int(self[o + 1]) }
    func be32(_ o: Int) -> Int {
        Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }
    func be64(_ o: Int) -> UInt64 { UInt64(be32(o)) << 32 | UInt64(be32(o + 4)) }

    mutating func putBE32(_ v: Int, at o: Int) {
        self[o] = UInt8(truncatingIfNeeded: v >> 24)
        self[o + 1] = UInt8(truncatingIfNeeded: v >> 16)
        self[o + 2] = UInt8(truncatingIfNeeded: v >> 8)
        self[o + 3] = UInt8(truncatingIfNeeded: v)
    }

    mutating func putBE64(_ v: UInt64, at o: Int) {
        putBE32(Int(v >> 32), at: o)
        putBE32(Int(v & 0xFFFF_FFFF), at: o + 4)
    }

    mutating func appendBE16(_ v: Int) { append(UInt8(truncatingIfNeeded: v >> 8)); append(UInt8(truncatingIfNeeded: v)) }
    mutating func appendBE32(_ v: Int) {
        for s in stride(from: 24, through: 0, by: -8) { append(UInt8(truncatingIfNeeded: v >> s)) }
    }
    mutating func appendBE64(_ v: UInt64) { appendBE32(Int(v >> 32)); appendBE32(Int(v & 0xFFFF_FFFF)) }
    mutating func appendFourCC(_ s: String) {
        let bytes = Array(s.utf8)
        precondition(bytes.count == 4 || s.unicodeScalars.count == 4)
        if bytes.count == 4 { append(contentsOf: bytes); return }
        // "©nam": © is a single Latin-1 byte 0xA9 in MP4 atoms
        append(contentsOf: s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }
}

func fourCC(_ bytes: ArraySlice<UInt8>) -> String {
    String(bytes.map { Character(UnicodeScalar($0)) })
}

/// A node of the box tree. Containers hold children, leaves hold an opaque payload.
final class MP4Node {
    var type: String
    var payload: [UInt8]
    var children: [MP4Node]?

    static let containerTypes: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "edts", "dinf"]

    init(type: String, payload: [UInt8] = [], children: [MP4Node]? = nil) {
        self.type = type
        self.payload = payload
        self.children = children
    }

    var isContainer: Bool { children != nil }

    func child(_ type: String) -> MP4Node? { children?.first { $0.type == type } }

    func path(_ types: String...) -> MP4Node? {
        var node: MP4Node? = self
        for t in types { node = node?.child(t) }
        return node
    }

    var serialized: [UInt8] {
        var body: [UInt8] = payload
        if let children { body = children.flatMap(\.serialized) }
        var out: [UInt8] = []
        out.reserveCapacity(body.count + 16)
        let total = body.count + 8
        if total > Int(UInt32.max) {
            out.appendBE32(1)
            out.appendFourCC(type)
            out.appendBE64(UInt64(body.count + 16))
        } else {
            out.appendBE32(total)
            out.appendFourCC(type)
        }
        out.append(contentsOf: body)
        return out
    }

    /// Parses sibling boxes in `bytes[range]`; known containers are descended into.
    static func parse(_ bytes: [UInt8], range: Range<Int>) throws -> [MP4Node] {
        var nodes: [MP4Node] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = bytes.be32(pos)
            let type = fourCC(bytes[pos + 4..<pos + 8])
            var header = 8
            if size == 1 {
                guard pos + 16 <= range.upperBound else { throw MP4Error.malformed("large size") }
                size = Int(bytes.be64(pos + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= header, pos + size <= range.upperBound else {
                throw MP4Error.malformed("box '\(type)' exceeds its parent")
            }
            let inner = pos + header..<pos + size
            if containerTypes.contains(type) {
                nodes.append(MP4Node(type: type, children: try parse(bytes, range: inner)))
            } else {
                nodes.append(MP4Node(type: type, payload: Array(bytes[inner])))
            }
            pos += size
        }
        return nodes
    }
}

/// Positions of the top-level boxes in the source file.
struct TopLevelBox {
    var type: String
    var start: Int
    var headerSize: Int
    var size: Int
    var payloadStart: Int { start + headerSize }
    var end: Int { start + size }
}

func scanTopLevel(_ file: UnsafeRawBufferPointer) throws -> [TopLevelBox] {
    var boxes: [TopLevelBox] = []
    var pos = 0
    func be32(_ o: Int) -> Int {
        Int(file[o]) << 24 | Int(file[o + 1]) << 16 | Int(file[o + 2]) << 8 | Int(file[o + 3])
    }
    while pos + 8 <= file.count {
        var size = be32(pos)
        let type = String((4..<8).map { Character(UnicodeScalar(file[pos + $0])) })
        var header = 8
        if size == 1 {
            guard pos + 16 <= file.count else { throw MP4Error.malformed("large size") }
            size = Int(UInt64(be32(pos + 8)) << 32 | UInt64(be32(pos + 12)))
            header = 16
        } else if size == 0 {
            size = file.count - pos
        }
        guard size >= header, pos + size <= file.count else {
            throw MP4Error.malformed("top-level box '\(type)' is truncated")
        }
        boxes.append(TopLevelBox(type: type, start: pos, headerSize: header, size: size))
        pos += size
    }
    return boxes
}

/// Sample table of one track, reduced to what the remuxer needs.
struct SampleTable {
    var sampleSizes: [Int]
    var chunkOffsets: [UInt64]
    var chunkRuns: [(firstChunk: Int, samplesPerChunk: Int)]
    var usesCo64: Bool

    init(stbl: MP4Node) throws {
        guard let stsz = stbl.child("stsz")?.payload, stsz.count >= 12,
              let stsc = stbl.child("stsc")?.payload, stsc.count >= 8
        else { throw MP4Error.malformed("sample table incomplete") }

        let fixed = stsz.be32(4)
        let count = stsz.be32(8)
        if fixed != 0 {
            sampleSizes = Array(repeating: fixed, count: count)
        } else {
            guard stsz.count >= 12 + count * 4 else { throw MP4Error.malformed("stsz") }
            sampleSizes = (0..<count).map { stsz.be32(12 + $0 * 4) }
        }

        let runCount = stsc.be32(4)
        guard stsc.count >= 8 + runCount * 12 else { throw MP4Error.malformed("stsc") }
        chunkRuns = (0..<runCount).map { (stsc.be32(8 + $0 * 12), stsc.be32(12 + $0 * 12)) }

        if let stco = stbl.child("stco")?.payload {
            usesCo64 = false
            let n = stco.be32(4)
            guard stco.count >= 8 + n * 4 else { throw MP4Error.malformed("stco") }
            chunkOffsets = (0..<n).map { UInt64(stco.be32(8 + $0 * 4)) }
        } else if let co64 = stbl.child("co64")?.payload {
            usesCo64 = true
            let n = co64.be32(4)
            guard co64.count >= 8 + n * 8 else { throw MP4Error.malformed("co64") }
            chunkOffsets = (0..<n).map { co64.be64(8 + $0 * 8) }
        } else {
            throw MP4Error.malformed("no chunk offset table")
        }
    }

    /// Absolute (file) offset and size of every sample, in sample order.
    func sampleExtents() throws -> [(offset: Int, size: Int)] {
        var extents: [(Int, Int)] = []
        extents.reserveCapacity(sampleSizes.count)
        var sample = 0
        for chunk in 0..<chunkOffsets.count {
            let chunkNo = chunk + 1
            var perChunk = 0
            for run in chunkRuns where run.firstChunk <= chunkNo { perChunk = run.samplesPerChunk }
            var offset = Int(chunkOffsets[chunk])
            for _ in 0..<perChunk {
                guard sample < sampleSizes.count else { break }
                extents.append((offset, sampleSizes[sample]))
                offset += sampleSizes[sample]
                sample += 1
            }
        }
        guard sample == sampleSizes.count else { throw MP4Error.malformed("sample/chunk tables disagree") }
        return extents
    }
}

extension MP4Node {
    /// Shifts every chunk offset of this `stbl` by `delta`.
    func shiftChunkOffsets(by delta: Int) throws {
        if let stco = child("stco") {
            let n = stco.payload.be32(4)
            for i in 0..<n {
                let v = stco.payload.be32(8 + i * 4) + delta
                guard v >= 0, v <= Int(UInt32.max) else { throw MP4Error.unsupported("file too large for 32-bit offsets") }
                stco.payload.putBE32(v, at: 8 + i * 4)
            }
        }
        if let co64 = child("co64") {
            let n = co64.payload.be32(4)
            for i in 0..<n {
                let v = Int(co64.payload.be64(8 + i * 8)) + delta
                guard v >= 0 else { throw MP4Error.malformed("negative chunk offset") }
                co64.payload.putBE64(UInt64(v), at: 8 + i * 8)
            }
        }
    }

    /// Handler type (`soun`, `text`, ...) of a `trak`.
    var handlerType: String? {
        guard let hdlr = path("mdia", "hdlr")?.payload, hdlr.count >= 12 else { return nil }
        return fourCC(hdlr[8..<12])
    }
}
