import CommonCrypto
import Foundation

@testable import BookLibCore

/// Builds a minimal AAXC-like MP4: an audio track (sample entry `aavd`, encrypted samples) and a
/// text track (chapter titles), both interleaved in a single `mdat`.
enum SyntheticAAXC {
    static let key = Data((0..<16).map { UInt8($0 * 7 + 1) })
    static let iv = Data((0..<16).map { UInt8(255 - $0 * 3) })

    struct Result {
        var file: Data
        var plainSamples: [[UInt8]]
        var textSamples: [[UInt8]]
    }

    static func encrypt(_ sample: [UInt8]) -> [UInt8] {
        let blocks = sample.count & ~0xF
        var out = sample
        guard blocks > 0 else { return out }
        var moved = 0
        out.withUnsafeMutableBytes { dst in
            sample.withUnsafeBytes { src in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        _ = CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, 16,
                            v.baseAddress, src.baseAddress, blocks, dst.baseAddress, blocks, &moved)
                    }
                }
            }
        }
        return out
    }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        MP4Node(type: type, payload: payload).serialized
    }

    static func container(_ type: String, _ kids: [[UInt8]]) -> [UInt8] {
        var body: [UInt8] = []
        kids.forEach { body += $0 }
        return box(type, body)
    }

    static func fullBox(_ type: String, _ fields: [UInt8]) -> [UInt8] { box(type, [0, 0, 0, 0] + fields) }

    static func be32(_ v: Int) -> [UInt8] { var a: [UInt8] = []; a.appendBE32(v); return a }

    static func build(audioSamples: Int = 40, withTextTrack: Bool = true, co64: Bool = false) -> Result {
        var plain: [[UInt8]] = []
        for i in 0..<audioSamples {
            // varying sizes, including ones that are not a multiple of 16 and one tiny sample
            let size = i == 3 ? 7 : 40 + (i * 13) % 200
            plain.append((0..<size).map { UInt8(truncatingIfNeeded: i * 31 + $0 * 17) })
        }
        let text: [[UInt8]] = [Array("Chapter 1".utf8), Array("Chapter 2".utf8)]

        // chunking: 4 audio samples per chunk, text chunks after chunk 3 and 6
        var chunks: [(track: Int, samples: [[UInt8]])] = []
        var textIdx = 0
        var chunkNo = 0
        for start in stride(from: 0, to: plain.count, by: 4) {
            chunks.append((0, Array(plain[start..<min(start + 4, plain.count)].map(encrypt))))
            chunkNo += 1
            if withTextTrack && (chunkNo == 3 || chunkNo == 6) && textIdx < text.count {
                chunks.append((1, [text[textIdx]]))
                textIdx += 1
            }
        }

        func moov(mdatStart: Int) -> [UInt8] {
            // compute offsets for given mdat payload start
            var audioOffsets: [Int] = [], textOffsets: [Int] = []
            var pos = mdatStart
            for c in chunks {
                if c.track == 0 { audioOffsets.append(pos) } else { textOffsets.append(pos) }
                pos += c.samples.reduce(0) { $0 + $1.count }
            }

            func track(handler: String, entry: [UInt8], sizes: [Int], perChunk: Int, offsets: [Int]) -> [UInt8] {
                var hdlr: [UInt8] = [0, 0, 0, 0]
                hdlr += [0, 0, 0, 0] // pre_defined
                hdlr.appendFourCC(handler)
                hdlr += [UInt8](repeating: 0, count: 12) + [0]
                var stsd: [UInt8] = be32(1)
                stsd += entry
                var stsz = [UInt8]()
                stsz += be32(0) + be32(sizes.count)
                sizes.forEach { stsz += be32($0) }
                let stsc = be32(1) + be32(1) + be32(perChunk) + be32(1)
                var chunkTable: [UInt8]
                if co64 {
                    chunkTable = be32(offsets.count)
                    offsets.forEach { chunkTable.appendBE64(UInt64($0)) }
                } else {
                    chunkTable = be32(offsets.count)
                    offsets.forEach { chunkTable += be32($0) }
                }
                let stbl = container("stbl", [
                    fullBox("stsd", Array(stsd)),
                    fullBox("stsz", Array(stsz.dropFirst(0))),
                    fullBox("stsc", Array(stsc)),
                    fullBox(co64 ? "co64" : "stco", chunkTable),
                ])
                return container("trak", [
                    container("mdia", [fullBox("hdlr", Array(hdlr.dropFirst(4))), container("minf", [stbl])])
                ])
            }

            // sample entry for audio: 16 bytes header after size/type + 28
            var entry: [UInt8] = [UInt8](repeating: 0, count: 6) + [0, 1] + [0, 0, 0, 0, 0, 0, 0, 0]
            entry.appendBE16(2)       // channels
            entry.appendBE16(16)      // sample size
            entry += [0, 0, 0, 0]
            entry.appendBE16(44100); entry.appendBE16(0)
            let audioEntry = box("aavd", entry)
            let textEntry = box("text", [UInt8](repeating: 0, count: 8))

            var kids = [track(handler: "soun", entry: audioEntry, sizes: plain.map(\.count), perChunk: 4,
                              offsets: audioOffsets)]
            if withTextTrack {
                kids.append(track(handler: "text", entry: textEntry, sizes: text.map(\.count), perChunk: 1,
                                  offsets: textOffsets))
            }
            return container("moov", kids)
        }

        var ftyp: [UInt8] = []
        ftyp.appendFourCC("aaxc"); ftyp.appendBE32(0); ftyp.appendFourCC("aaxc"); ftyp.appendFourCC("isom")
        let ftypBox = box("ftyp", ftyp)
        // file layout: ftyp | free | moov | mdat
        let free = box("free", [UInt8](repeating: 0, count: 24))
        let moovSize = moov(mdatStart: 0).count
        let mdatHeader = 8
        let mdatStart = ftypBox.count + free.count + moovSize + mdatHeader
        let moovBox = moov(mdatStart: mdatStart)

        var mdatBody: [UInt8] = []
        chunks.forEach { c in c.samples.forEach { mdatBody += $0 } }
        let file = ftypBox + free + moovBox + box("mdat", mdatBody)
        return Result(file: Data(file), plainSamples: plain, textSamples: text)
    }
}
