import AVFoundation
import Foundation
import Testing

@testable import BookLibCore

private let ffmpegPath: String? = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.enabled(if: ffmpegPath != nil, "ffmpeg not installed"))
struct RealAudioTests {
    func run(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath!)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Turns a real AAC file into an "AAXC" lookalike: encrypts every audio sample in place and
    /// renames the sample entry to `aavd`.
    func fabricateAAXC(from m4a: URL, to aaxc: URL) throws {
        var data = try Data(contentsOf: m4a)
        let (extents, stsdTypeOffset): ([(offset: Int, size: Int)], Int) = try data.withUnsafeBytes { raw in
            let boxes = try scanTopLevel(raw)
            let moovBox = boxes.first { $0.type == "moov" }!
            let bytes = [UInt8](data[moovBox.start..<moovBox.end])
            let moov = try MP4Node.parse(bytes, range: 0..<bytes.count)[0]
            let audio = moov.children!.first { $0.handlerType == "soun" }!
            let table = try SampleTable(stbl: audio.path("mdia", "minf", "stbl")!)
            // locate "mp4a" inside the moov bytes (first occurrence is the stsd entry type)
            let needle = Array("mp4a".utf8)
            var idx = 0
            for i in 0..<(bytes.count - 4) where Array(bytes[i..<i + 4]) == needle { idx = i; break }
            return (try table.sampleExtents(), moovBox.start + idx)
        }
        for e in extents {
            let enc = SyntheticAAXC.encrypt([UInt8](data[e.offset..<e.offset + e.size]))
            data.replaceSubrange(e.offset..<e.offset + e.size, with: enc)
        }
        data.replaceSubrange(stsdTypeOffset..<stsdTypeOffset + 4, with: Data("aavd".utf8))
        try data.write(to: aaxc)
    }

    @Test func remuxedFileDecodesIdenticallyAndPlaysInAVFoundation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blc-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let m4a = dir.appendingPathComponent("orig.m4a")
        _ = try run([
            "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=20", "-ac", "2", "-ar", "44100",
            "-c:a", "aac", "-b:a", "64k", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", m4a.path,
        ])
        try #require(FileManager.default.fileExists(atPath: m4a.path))

        let aaxc = dir.appendingPathComponent("book.aaxc")
        try fabricateAAXC(from: m4a, to: aaxc)

        // the fabricated file must NOT decode as audio
        let m4b = dir.appendingPathComponent("book.m4b")
        let result = try AAXCRemuxer.convert(
            input: aaxc, output: m4b, keyHex: SyntheticAAXC.key.hexString, ivHex: SyntheticAAXC.iv.hexString,
            chapters: {
                var ci = ChapterInfo()
                ci.chapters = [Chapter(title: "One", lengthMs: 10_000, startOffsetMs: 0),
                               Chapter(title: "Two", lengthMs: 10_000, startOffsetMs: 10_000)]
                return ci
            }(),
            metadata: M4BMetadata(title: "Synthetic Book", author: "Test Author", year: 2020))
        #expect(result.channelCount == 2)

        // decoded PCM must be bit-identical to decoding the original
        let a = try run(["-v", "error", "-i", m4a.path, "-map", "0:a", "-f", "md5", "-"])
        let b = try run(["-v", "error", "-i", m4b.path, "-map", "0:a", "-f", "md5", "-"])
        #expect(a.hasPrefix("MD5="))
        #expect(a == b)

        // chapters and tags are visible to ffprobe-style tools
        let info = try run(["-i", m4b.path, "-f", "ffmetadata", "-"])
        #expect(info.contains("title=Synthetic Book"))
        #expect(info.contains("artist=Test Author"))
        #expect(info.contains("title=One"))
        #expect(info.contains("title=Two"))

        // and the system media stack accepts it
        let asset = AVURLAsset(url: m4b)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 20) < 0.5)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1)
        let chapters = try await asset.load(.availableChapterLocales)
        _ = chapters
    }
}
