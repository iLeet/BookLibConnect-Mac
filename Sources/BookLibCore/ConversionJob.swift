import Foundation

public enum ProgressEvent: Sendable {
    /// A run over `count` items starts: resets all bars.
    case start(count: Int)
    /// The next item enters license/download: resets the download bar.
    case nextItem
    case download(Double)
    case decrypt(ConversionRef, Double)
    case export(ConversionRef, Double)
}

/// Downloads, decrypts and (optionally) exports a list of conversions.
///
/// Licenses and downloads run one after another; decryption runs in the background, one file at a
/// time, so the next download can already proceed. A book is exported when all its units are unlocked.
@MainActor
public final class ConversionJob {
    private let store: LibraryStore
    private let api: AudibleAPI
    private let settings: JobSettings
    private let onProgress: @Sendable (ProgressEvent) -> Void
    private let onChange: (ConversionRef) -> Void
    private let cancelFlag = CancelFlag()

    private var decryptTasks: [Task<Void, Never>] = []
    private var exportedBooks = Set<String>()
    private let decryptGate = AsyncGate()

    public init(
        store: LibraryStore, api: AudibleAPI, settings: JobSettings,
        onProgress: @escaping @Sendable (ProgressEvent) -> Void,
        onChange: @escaping (ConversionRef) -> Void
    ) {
        self.store = store
        self.api = api
        self.settings = settings
        self.onProgress = onProgress
        self.onChange = onChange
    }

    public func cancel() { cancelFlag.cancel() }

    public func run(_ refs: [ConversionRef]) async {
        onProgress(.start(count: refs.count))
        for ref in refs {
            if cancelFlag.isCancelled { break }
            onProgress(.nextItem)
            await licenseAndDownload(ref)
        }
        for task in decryptTasks { await task.value }
        decryptTasks.removeAll()
    }

    // MARK: - License + download

    private func licenseAndDownload(_ ref: ConversionRef) async {
        guard let unit = store.unit(for: ref), let book = store.book(ref.bookAsin) else { return }

        let fm = FileManager.default
        let hasLocked = unit.downloadFileName.map { fm.fileExists(atPath: $0 + FileExt.encrypted) } ?? false
        let hasUnlocked = unit.downloadFileName.map { fm.fileExists(atPath: $0 + FileExt.decrypted) } ?? false

        var doDownload = unit.state < .localLocked || !hasLocked
        var doDecrypt = unit.state < .localUnlocked || !hasUnlocked

        let higherQuality = settings.downloadQuality > book.applicableQuality(multiPart: settings.multiPartDownload)
        if higherQuality {
            doDownload = true
            doDecrypt = true
        }

        if doDownload && doDecrypt {
            guard await obtainLicense(ref) else { return }
            guard await download(ref) else { return }
        }

        guard !cancelFlag.isCancelled else { return }
        let task = Task { [self] in await decryptAndExport(ref) }
        decryptTasks.append(task)
    }

    private var licenseURLs: [String: URL] = [:]

    private func obtainLicense(_ ref: ConversionRef) async -> Bool {
        store.setState(ref, .download)
        onChange(ref)
        do {
            let granted = try await api.licenseRequest(asin: ref.unitAsin, quality: settings.downloadQuality)
            guard let urlString = granted.license.content_metadata?.content_url?.offline_url,
                  let url = URL(string: urlString)
            else { throw AudibleError.licenseDenied("no download URL") }
            store.applyLicense(
                granted.license, voucher: granted.voucher, to: ref,
                quality: settings.downloadQuality, downloadDirectory: settings.downloadDirectory)
            licenseURLs[ref.unitAsin] = url
            onChange(ref)
            return true
        } catch {
            NSLog("License for \(ref.unitAsin) failed: \(error)")
            store.setState(ref, .licenseDenied)
            onChange(ref)
            return false
        }
    }

    private func download(_ ref: ConversionRef) async -> Bool {
        guard let unit = store.unit(for: ref), let stub = unit.downloadFileName,
              let url = licenseURLs[ref.unitAsin]
        else { return false }
        store.setState(ref, .downloading)
        onChange(ref)

        let expected = unit.fileSizeBytes ?? 0
        let events = onProgress
        do {
            let written = try await api.download(from: url, to: URL(fileURLWithPath: stub + FileExt.encrypted)) { received, total in
                let size = Double(expected > 0 ? expected : (total ?? 0))
                if size > 0 { events(.download(min(1, Double(received) / size))) }
            }
            guard expected == 0 || written >= expected else {
                store.setState(ref, .downloadError)
                onChange(ref)
                return false
            }
            store.setState(ref, .localLocked)
            onChange(ref)
            events(.download(1))
            return true
        } catch {
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled { NSLog("Download of \(ref.unitAsin) failed: \(error)") }
            store.setState(ref, cancelled ? .remote : .downloadError)
            onChange(ref)
            return false
        }
    }

    // MARK: - Decrypt + export

    private func decryptAndExport(_ ref: ConversionRef) async {
        guard let unit = store.unit(for: ref) else { return }
        let fm = FileManager.default
        let hasUnlocked = unit.downloadFileName.map { fm.fileExists(atPath: $0 + FileExt.decrypted) } ?? false

        var success = true
        if unit.state < .localUnlocked || !hasUnlocked {
            await decryptGate.acquire()
            success = await decrypt(ref)
            await decryptGate.release()
            if success && !settings.keepEncryptedFiles, let stub = store.unit(for: ref)?.downloadFileName {
                try? fm.removeItem(atPath: stub + FileExt.encrypted)
            }
        } else {
            onProgress(.decrypt(ref, 1))
        }

        guard success, settings.exportToAax, let exportDir = settings.exportDirectory,
              !cancelFlag.isCancelled
        else { return }
        await exportIfComplete(ref, exportDirectory: exportDir)
    }

    private func decrypt(_ ref: ConversionRef) async -> Bool {
        guard let unit = store.unit(for: ref), let book = store.book(ref.bookAsin),
              let stub = unit.downloadFileName,
              let key = unit.licenseKey, let iv = unit.licenseIv
        else {
            store.setState(ref, .unlockingFailed)
            onChange(ref)
            return false
        }
        store.setState(ref, .unlocking)
        onChange(ref)

        let input = URL(fileURLWithPath: stub + FileExt.encrypted)
        let output = URL(fileURLWithPath: stub + FileExt.decrypted)
        guard FileManager.default.fileExists(atPath: input.path) else {
            store.setState(ref, .unlockingFailed)
            onChange(ref)
            return false
        }

        let cover = store.coverURL(for: book).flatMap { try? Data(contentsOf: $0) }
        let metadata = Self.metadata(for: unit, of: book, cover: cover)
        let events = onProgress
        let flag = cancelFlag
        let chapters = unit.chapterInfo

        let result: Result<RemuxResult, Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try AAXCRemuxer.convert(
                    input: input, output: output, keyHex: key, ivHex: iv,
                    chapters: chapters, metadata: metadata,
                    progress: { events(.decrypt(ref, $0)) },
                    isCancelled: { flag.isCancelled })
            }
        }.value

        switch result {
        case .success(let info):
            store.setState(ref, .localUnlocked)
            events(.decrypt(ref, 1))
            // name files after their channel layout, as the original does
            let suffix = info.channelCount == 1 ? "_Mono" : "_Stereo"
            let fm = FileManager.default
            do {
                try Self.move(stub + FileExt.encrypted, to: stub + suffix + FileExt.encrypted, fm: fm)
                try Self.move(stub + FileExt.decrypted, to: stub + suffix + FileExt.decrypted, fm: fm)
                store.saveFileNameSuffix(ref, suffix: suffix)
            } catch {
                NSLog("Renaming failed: \(error)")
            }
            onChange(ref)
            return true
        case .failure(let error):
            if case RemuxError.cancelled = error {
                store.setState(ref, .localLocked)
            } else {
                NSLog("Decryption of \(ref.unitAsin) failed: \(error)")
                store.setState(ref, .unlockingFailed)
            }
            onChange(ref)
            return false
        }
    }

    private static func move(_ from: String, to: String, fm: FileManager) throws {
        guard fm.fileExists(atPath: from) else { return }
        try? fm.removeItem(atPath: to)
        try fm.moveItem(atPath: from, toPath: to)
    }

    private func exportIfComplete(_ ref: ConversionRef, exportDirectory: String) async {
        guard let book = store.book(ref.bookAsin), !exportedBooks.contains(book.asin) else { return }
        guard book.applicableState(multiPart: settings.multiPartDownload) >= .localUnlocked else { return }
        let fm = FileManager.default
        for u in book.units(multiPart: settings.multiPartDownload) {
            guard let stub = u.downloadFileName, fm.fileExists(atPath: stub + FileExt.decrypted) else { return }
        }
        exportedBooks.insert(book.asin)

        let exporter = AaxExporter(
            exportDirectory: URL(fileURLWithPath: exportDirectory, isDirectory: true),
            multiPart: settings.multiPartDownload)
        let events = onProgress
        let flag = cancelFlag
        await exporter.export(
            book: book, store: store,
            progress: { events(.export($0, $1)) },
            isCancelled: { flag.isCancelled })
        for u in book.units(multiPart: settings.multiPartDownload) {
            onChange(ConversionRef(bookAsin: book.asin, unitAsin: u.asin))
        }
    }

    static func metadata(for unit: MediaUnit, of book: Book, cover: Data?) -> M4BMetadata {
        var title = book.title
        if unit.asin != book.asin {
            title = unit.title ?? "\(book.title), Part \(unit.partNumber)"
        }
        return M4BMetadata(
            title: title, author: book.allAuthors, narrator: book.allNarrators, album: book.title,
            genre: book.genres.first?.last, year: book.releaseYear,
            comment: book.publisherSummary.map(Self.stripHTML), coverImage: cover)
    }

    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Thread-safe cancel switch shared with background work.
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { flag } }
    public func cancel() { lock.withLock { flag = true } }
}

/// Binary async semaphore (decryptions are throttled to one at a time).
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
