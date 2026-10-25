import BookLibCore
import AppKit
import Foundation

/// `BLC_DEMO=1` launches the app with a throw-away library of public-domain titles and no network
/// access. Handy for screenshots and for trying the interface without an Audible account.
enum Demo {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["BLC_DEMO"] == "1" }

    static func directory() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("BookLibConnect-Demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "com.github.ileet.BookLibConnect-Mac.demo")!
        d.removePersistentDomain(forName: "com.github.ileet.BookLibConnect-Mac.demo")
        return d
    }

    private struct Title {
        var asin: String, title: String, author: String, narrator: String, hours: Double, year: Int
        var series: (String, String)? = nil
        var genre: [String] = ["Literature & Fiction", "Classics"]
        var parts = 0
        var summary: String
        var state: ConversionState = .remote
    }

    private static let titles: [Title] = [
        .init(asin: "B000DEMO01", title: "Pride and Prejudice", author: "Jane Austen", narrator: "Anne Flosnik",
              hours: 12.54, year: 2008, parts: 2,
              summary: "<p>First published in 1813, this is Jane Austen’s most popular novel. It portrays life in the genteel rural society of the day, and tells of the initial misunderstandings and later mutual enlightenment between the lively and quick-witted Elizabeth Bennet and the proud and haughty Fitzwilliam Darcy.</p>",
              state: .exported),
        .init(asin: "B000DEMO02", title: "Emma", author: "Jane Austen", narrator: "Juliet Stevenson", hours: 16.2, year: 2010,
              summary: "<p>Emma Woodhouse, handsome, clever, and rich, is mistress of her father’s house and sure of her own judgment — and sure to meddle.</p>",
              state: .localUnlocked),
        .init(asin: "B000DEMO03", title: "Moby-Dick; or, The Whale", author: "Herman Melville", narrator: "William Hootkins",
              hours: 24.7, year: 2005, genre: ["Literature & Fiction", "Action & Adventure"],
              summary: "<p>Call me Ishmael. Some years ago, never mind how long precisely, I thought I would sail about a little and see the watery part of the world.</p>"),
        .init(asin: "B000DEMO04", title: "A Study in Scarlet", author: "Arthur Conan Doyle", narrator: "Stephen Fry",
              hours: 4.1, year: 2011, series: ("Sherlock Holmes", "1"), genre: ["Mystery, Thriller & Suspense"],
              summary: "<p>The first appearance of Sherlock Holmes and Dr. Watson, and the case that brings them together.</p>",
              state: .localLocked),
        .init(asin: "B000DEMO05", title: "The Sign of the Four", author: "Arthur Conan Doyle", narrator: "Stephen Fry",
              hours: 3.6, year: 2011, series: ("Sherlock Holmes", "2"), genre: ["Mystery, Thriller & Suspense"],
              summary: "<p>A mysterious treasure, a dead man, and a woman in need of help.</p>"),
        .init(asin: "B000DEMO06", title: "Frankenstein; or, The Modern Prometheus", author: "Mary Shelley",
              narrator: "Dan Stevens", hours: 8.9, year: 2018, genre: ["Science Fiction & Fantasy", "Classics"],
              summary: "<p>Victor Frankenstein’s ambition to create life leads to tragedy.</p>"),
        .init(asin: "B000DEMO07", title: "Dracula", author: "Bram Stoker", narrator: "Alan Cumming",
              hours: 15.3, year: 2016, genre: ["Horror"],
              summary: "<p>Told through letters and diary entries, Count Dracula’s journey from Transylvania to England.</p>"),
        .init(asin: "B000DEMO08", title: "Great Expectations", author: "Charles Dickens", narrator: "Simon Vance",
              hours: 18.8, year: 2007, summary: "<p>Pip, an orphan, is given a mysterious fortune.</p>", state: .exported),
        .init(asin: "B000DEMO09", title: "The Time Machine", author: "H. G. Wells", narrator: "Michael Sheen",
              hours: 3.2, year: 2014, genre: ["Science Fiction & Fantasy"],
              summary: "<p>The Time Traveller’s journey to the year 802,701.</p>"),
        .init(asin: "B000DEMO10", title: "Treasure Island", author: "Robert Louis Stevenson", narrator: "Alfred Molina",
              hours: 7.7, year: 2012, genre: ["Literature & Fiction", "Action & Adventure"],
              summary: "<p>Young Jim Hawkins, a map, and the pirate Long John Silver.</p>"),
        .init(asin: "B000DEMO11", title: "Alice’s Adventures in Wonderland", author: "Lewis Carroll",
              narrator: "Scarlett Johansson", hours: 2.6, year: 2013, genre: ["Children’s Audiobooks"],
              summary: "<p>Down the rabbit hole into a world of nonsense.</p>"),
        .init(asin: "B000DEMO12", title: "The Picture of Dorian Gray", author: "Oscar Wilde", narrator: "Tim Pigott-Smith",
              hours: 8.4, year: 2009, summary: "<p>A portrait ages while its subject does not.</p>"),
    ]

    /// Generated placeholder cover (own artwork, no publisher imagery).
    static func cover(title: String, author: String, hue: Double) -> Data? {
        let size = NSSize(width: 500, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(colors: [
            NSColor(hue: hue, saturation: 0.55, brightness: 0.55, alpha: 1),
            NSColor(hue: hue + 0.06, saturation: 0.65, brightness: 0.85, alpha: 1),
        ])!.draw(in: NSRect(origin: .zero, size: size), angle: -60)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let frame = NSBezierPath(rect: NSRect(x: 28, y: 28, width: 444, height: 444))
        frame.lineWidth = 3
        frame.stroke()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Georgia-Bold", size: 46) ?? NSFont.boldSystemFont(ofSize: 46),
            .foregroundColor: NSColor.white, .paragraphStyle: para,
        ]
        let authorAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Georgia-Italic", size: 28) ?? NSFont.systemFont(ofSize: 28),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: para,
        ]
        (title.uppercased() as NSString).draw(in: NSRect(x: 50, y: 190, width: 400, height: 240), withAttributes: titleAttrs)
        (author as NSString).draw(in: NSRect(x: 50, y: 70, width: 400, height: 60), withAttributes: authorAttrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    @MainActor
    static func seed(_ model: AppModel) {
        switch ProcessInfo.processInfo.environment["BLC_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let s = model.settings
        s.multiPartDownload = true
        s.autoUpdateLibrary = true
        s.downloadDirectory = directory().appendingPathComponent("Download").path
        s.exportDirectory = directory().appendingPathComponent("Export").path
        s.exportToAax = true
        try? FileManager.default.createDirectory(atPath: s.downloadDirectory!, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: s.exportDirectory!, withIntermediateDirectories: true)

        var profile = Profile(region: .us, preAmazon: false, serial: "DEMO")
        profile.customerInfo = CustomerInfo(name: "Demo Listener", accountId: "amzn1.account.DEMO")
        profile.deviceInfo = DeviceInfo(type: "A2CZJZGLK2JJVM", name: "Demo’s Audible for iPhone", serial: "DEMO")
        let account = model.store.addAccount(audibleId: "amzn1.account.DEMO", alias: "Account 1")

        var products: [Product] = []
        var date = Date()
        for t in titles {
            var p = Product()
            p.asin = t.asin
            p.title = t.title
            p.authors = [Person(asin: nil, name: t.author)]
            p.narrators = [Person(asin: nil, name: t.narrator)]
            p.runtime_length_min = Int(t.hours * 60)
            p.release_date = Calendar.current.date(from: DateComponents(year: t.year, month: 1, day: 4))
            p.purchase_date = date
            date = date.addingTimeInterval(-86_400 * 9)
            p.language = "english"
            p.format_type = "unabridged"
            p.publisher_summary = t.summary
            p.publisher_name = "Public Domain Audio"
            p.content_delivery_type = t.parts > 0 ? "MultiPartBook" : "SinglePartBook"
            p.category_ladders = [ProductCategory(ladder: t.genre.map { LadderRung(id: nil, name: $0) }, root: "Genres")]
            var rel: [Relationship] = []
            for part in 0..<t.parts {
                rel.append(Relationship(
                    asin: "\(t.asin)P\(part + 1)", relationship_to_product: "child", relationship_type: "component",
                    sort: String(part + 1), title: "\(t.title) Part \(part + 1)"))
            }
            if let (name, seq) = t.series {
                rel.append(Relationship(
                    asin: "SERIES-\(name)", relationship_to_product: "parent", relationship_type: "series",
                    sequence: seq, sort: seq, title: name))
            }
            p.relationships = rel
            products.append(p)
        }
        model.store.merge(products: products, accountId: account.id, region: .us, resync: true)

        for t in titles where t.state != .remote {
            let ref = ConversionRef(bookAsin: t.asin, unitAsin: t.asin)
            model.store.mutate(ref) { $0.state = t.state }
            if t.parts > 0 {
                for part in 1...t.parts {
                    model.store.mutate(ConversionRef(bookAsin: t.asin, unitAsin: "\(t.asin)P\(part)")) {
                        $0.state = t.state
                        $0.fileSizeBytes = part == 1 ? 165_000_000 : 182_000_000
                        $0.sampleRate = 22050
                        $0.bitRate = 64
                        $0.runtimeSeconds = part == 1 ? 21_484 : 23_660
                    }
                }
            }
            model.store.mutate(ref) {
                $0.fileSizeBytes = Int64(t.hours * 13_000_000)
                $0.sampleRate = 22050
                $0.bitRate = 64
            }
        }

        model.profile = profile
        model.accountId = account.id
        model.accountAlias = account.alias
        model.api = AudibleAPI(profile: profile)
        s.profileAlias = account.alias
        s.profileRegion = .us
        for (i, t) in titles.enumerated() {
            let name = "\(t.asin).jpg"
            if let data = cover(title: t.title, author: t.author, hue: Double(i) / Double(titles.count)) {
                try? data.write(to: model.store.coverDirectory.appendingPathComponent(name))
                model.store.setCoverFile(name, forBook: t.asin)
            }
        }
        model.addToQueue(["B000DEMO01"])
        model.libraryPreselect = "B000DEMO01"
        switch ProcessInfo.processInfo.environment["BLC_OPEN"] {
        case "library": model.showLibrary = true
        case "profiles": model.showProfiles = true
        case "wizard": model.showWizard = true
        default: break
        }
    }
}
