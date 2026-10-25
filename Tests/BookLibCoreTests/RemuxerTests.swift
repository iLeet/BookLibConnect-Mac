import Foundation
import Testing

@testable import BookLibCore

@Suite struct RemuxerTests {
    func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("blc-\(UUID().uuidString)-\(name)")
    }

    /// Reads back the audio samples of a (plain) m4b produced by the remuxer.
    func readAudioSamples(_ data: Data) throws -> (samples: [[UInt8]], moov: MP4Node, entryType: String, ftyp: String) {
        try data.withUnsafeBytes { raw in
            let boxes = try scanTopLevel(raw)
            let moovBox = boxes.first { $0.type == "moov" }!
            let bytes = [UInt8](data[moovBox.start..<moovBox.end])
            let moov = try MP4Node.parse(bytes, range: 0..<bytes.count)[0]
            let audio = moov.children!.first { $0.handlerType == "soun" }!
            let stbl = audio.path("mdia", "minf", "stbl")!
            let table = try SampleTable(stbl: stbl)
            let samples = try table.sampleExtents().map { [UInt8](data[$0.offset..<$0.offset + $0.size]) }
            let entryType = fourCC(stbl.child("stsd")!.payload[12..<16])
            let ftypBox = boxes.first { $0.type == "ftyp" }!
            let ftyp = fourCC([UInt8](data[ftypBox.payloadStart..<ftypBox.payloadStart + 4])[0..<4])
            return (samples, moov, entryType, ftyp)
        }
    }

    @Test func decryptsAllSamplesAndRewritesContainer() throws {
        let src = SyntheticAAXC.build()
        let inURL = tmp("in.aaxc"), outURL = tmp("out.m4b")
        try src.file.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }

        let result = try AAXCRemuxer.convert(
            input: inURL, output: outURL, keyHex: SyntheticAAXC.key.hexString, ivHex: SyntheticAAXC.iv.hexString)
        #expect(result.channelCount == 2)
        #expect(result.sampleRate == 44100)
        #expect(result.sampleCount == 40)

        let out = try Data(contentsOf: outURL)
        let parsed = try readAudioSamples(out)
        #expect(parsed.entryType == "mp4a")
        #expect(parsed.ftyp == "M4B ")
        #expect(parsed.samples.count == src.plainSamples.count)
        for (i, s) in parsed.samples.enumerated() { #expect(s == src.plainSamples[i], "sample \(i)") }

        // the text (chapter) track must survive byte-for-byte at its new offsets
        let text = parsed.moov.children!.first { $0.handlerType == "text" }!
        let table = try SampleTable(stbl: text.path("mdia", "minf", "stbl")!)
        let textSamples = try table.sampleExtents().map { [UInt8](out[$0.offset..<$0.offset + $0.size]) }
        #expect(textSamples == src.textSamples)
    }

    @Test func supports64BitChunkOffsets() throws {
        let src = SyntheticAAXC.build(co64: true)
        let inURL = tmp("in64.aaxc"), outURL = tmp("out64.m4b")
        try src.file.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }
        _ = try AAXCRemuxer.convert(
            input: inURL, output: outURL, keyHex: SyntheticAAXC.key.hexString, ivHex: SyntheticAAXC.iv.hexString)
        let parsed = try readAudioSamples(try Data(contentsOf: outURL))
        #expect(parsed.samples == src.plainSamples)
    }

    @Test func addsChapterListAndTagsWhenSourceHasNone() throws {
        let src = SyntheticAAXC.build(withTextTrack: false)
        let inURL = tmp("in2.aaxc"), outURL = tmp("out2.m4b")
        try src.file.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL); try? FileManager.default.removeItem(at: outURL) }

        var info = ChapterInfo()
        info.chapters = [
            Chapter(title: "Opening", lengthMs: 1000, startOffsetMs: 0),
            Chapter(title: "Second", lengthMs: 2000, startOffsetMs: 1000),
        ]
        let meta = M4BMetadata(title: "A Title", author: "An Author", year: 2008, coverImage: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        _ = try AAXCRemuxer.convert(
            input: inURL, output: outURL, keyHex: SyntheticAAXC.key.hexString, ivHex: SyntheticAAXC.iv.hexString,
            chapters: info, metadata: meta)

        let out = try Data(contentsOf: outURL)
        let parsed = try readAudioSamples(out)
        #expect(parsed.samples == src.plainSamples)  // offsets still right after moov grew
        let udta = parsed.moov.child("udta")
        #expect(udta?.child("chpl") != nil)
        #expect(udta?.child("meta") != nil)
        let chpl = udta!.child("chpl")!.payload
        #expect(chpl[8] == 2)  // chapter count
    }

    @Test func rejectsWrongKeyFormat() {
        #expect(throws: RemuxError.self) {
            _ = try AAXCRemuxer.convert(
                input: URL(fileURLWithPath: "/nonexistent"), output: URL(fileURLWithPath: "/tmp/x"),
                keyHex: "zz", ivHex: "00")
        }
    }

    @Test func refusesFilesThatAreNotEncrypted() throws {
        var src = SyntheticAAXC.build()
        // flip aavd -> mp4a in the source file
        let needle = Data("aavd".utf8)
        let r = src.file.range(of: needle)!
        src.file.replaceSubrange(r, with: Data("mp4a".utf8))
        let inURL = tmp("plain.m4b"), outURL = tmp("plain-out.m4b")
        try src.file.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL) }
        #expect(throws: RemuxError.self) {
            _ = try AAXCRemuxer.convert(
                input: inURL, output: outURL, keyHex: SyntheticAAXC.key.hexString, ivHex: SyntheticAAXC.iv.hexString)
        }
        #expect(!FileManager.default.fileExists(atPath: outURL.path))
    }

    @Test func cancelLeavesNoPartialFile() throws {
        let src = SyntheticAAXC.build(audioSamples: 4000)
        let inURL = tmp("big.aaxc"), outURL = tmp("big.m4b")
        try src.file.write(to: inURL)
        defer { try? FileManager.default.removeItem(at: inURL) }
        #expect(throws: RemuxError.self) {
            _ = try AAXCRemuxer.convert(
                input: inURL, output: outURL, keyHex: SyntheticAAXC.key.hexString, ivHex: SyntheticAAXC.iv.hexString,
                isCancelled: { true })
        }
        #expect(!FileManager.default.fileExists(atPath: outURL.path))
        #expect(!FileManager.default.fileExists(atPath: outURL.appendingPathExtension("part").path))
    }
}
