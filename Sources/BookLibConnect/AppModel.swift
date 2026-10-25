import AppKit
import BookLibCore
import Observation
import SwiftUI

struct AliasRequest: Identifiable {
    let id = UUID()
    var customerName: String
    var localId: Int
    var currentAlias: String?
    var existing: Set<String>
    var resolve: (String?) -> Void
}

/// One row of the download list (a book, or a part of a multi-part book).
struct QueueRow: Identifiable, Hashable {
    var id: String { ref.unitAsin }
    var ref: ConversionRef
    var state: ConversionState
    var title: String
    var author: String
    var fileSize: Int64
    var duration: Int
    var year: Int
    var narrator: String
    var sampleRate: Int
    var bitRate: Int
}

@MainActor
@Observable
final class AppModel {
    // Services
    let settings: AppSettings
    let store: LibraryStore
    let profileStore: ProfileStore
    let supportDirectory: URL
    @ObservationIgnored let http = HTTPClient()

    // Profile
    var profile: Profile?
    var accountId: Int?
    var accountAlias: String?
    var api: AudibleAPI?

    // Download list
    var queuedBooks: [String] = []
    var selection = Set<String>()

    // Run state
    var isRunning = false
    var downloadFraction = 0.0
    var decryptFraction = 0.0
    var exportFraction = 0.0
    @ObservationIgnored private var itemCount = 0
    @ObservationIgnored private var decryptParts: [String: Double] = [:]
    @ObservationIgnored private var exportParts: [String: Double] = [:]
    @ObservationIgnored private var job: ConversionJob?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    // Presentation
    var busyMessage: String?
    var showLibrary = false
    var showProfiles = false
    var showWizard = false
    var aliasRequest: AliasRequest?
    var libraryPreselect: String?
    var initDone = false
    @ObservationIgnored private var libraryUpdated = false
    @ObservationIgnored private var fileCheckAnswered = false

    init() {
        let base: URL
        if Demo.isEnabled {
            base = Demo.directory().appendingPathComponent("Support", isDirectory: true)
            try? FileManager.default.removeItem(at: base)
            settings = AppSettings(defaults: Demo.defaults())
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BookLibConnect-Mac", isDirectory: true)
            settings = AppSettings()
        }
        supportDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = LibraryStore(directory: base)
        profileStore = ProfileStore(directory: base.appendingPathComponent("config", isDirectory: true))

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [store] _ in MainActor.assumeIsolated { store.saveNow() } }
    }

    // MARK: - Derived

    var region: Region? { profile?.region }

    var multiPart: Bool { settings.multiPartDownload }

    var queueRows: [QueueRow] {
        var rows: [QueueRow] = []
        for asin in queuedBooks {
            guard let book = store.book(asin) else { continue }
            for unit in book.units(multiPart: multiPart) {
                let state: ConversionState = unit.state <= .remote ? .download : unit.state
                rows.append(
                    QueueRow(
                        ref: ConversionRef(bookAsin: asin, unitAsin: unit.asin), state: state,
                        title: Self.title(of: unit, in: book), author: book.author ?? "",
                        fileSize: unit.fileSizeBytes ?? 0, duration: unit.runtimeSeconds ?? 0,
                        year: book.releaseYear ?? 0, narrator: book.narrator ?? "",
                        sampleRate: unit.sampleRate ?? 0, bitRate: unit.bitRate ?? 0))
            }
        }
        return rows
    }

    static func title(of unit: MediaUnit, in book: Book) -> String {
        if unit.asin == book.asin { return book.title }
        if let t = unit.title, !t.isEmpty { return t }
        return "\(book.title) Part \(unit.partNumber)"
    }

    var canRun: Bool {
        guard !isRunning, api != nil, !selection.isEmpty,
              let dir = settings.downloadDirectory, FileManager.default.fileExists(atPath: dir)
        else { return false }
        if settings.exportToAax ?? false {
            guard let e = settings.exportDirectory, FileManager.default.fileExists(atPath: e) else { return false }
        }
        return true
    }

    /// Books of the current profile, filtered and sorted like the library window shows them.
    var libraryBooks: [Book] {
        guard let accountId, let region else { return [] }
        var books = store.books(accountId: accountId, region: region)
        if !settings.includeAdultProducts { books = books.filter { !($0.adultProduct ?? false) } }
        if settings.hideUnavailableProducts { books = books.filter { $0.applicableState(multiPart: multiPart) != .unknown } }
        let byDate: (Book, Book) -> Bool = { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
        let author: (Book) -> String = { $0.author ?? "" }
        switch settings.initialSorting {
        case .stateDate:
            books.sort {
                let a = $0.applicableState(multiPart: multiPart), b = $1.applicableState(multiPart: multiPart)
                return a != b ? a < b : byDate($0, $1)
            }
        case .date: books.sort(by: byDate)
        case .authorTitle:
            books.sort { author($0) != author($1) ? author($0) < author($1) : $0.title < $1.title }
        case .authorDate:
            books.sort { author($0) != author($1) ? author($0) < author($1) : byDate($0, $1) }
        case .titleAuthor:
            books.sort { $0.title != $1.title ? $0.title < $1.title : author($0) < author($1) }
        }
        return books
    }

    // MARK: - Start-up

    func bootstrap() async {
        guard !initDone else { return }
        if Demo.isEnabled {
            Demo.seed(self)
            initDone = true
            return
        }
        busyMessage = "Initializing …"

        let existing = (try? await profileStore.all()) ?? []
        let needsWizard = existing.isEmpty
            || settings.downloadDirectory == nil
            || settings.exportToAax == nil
            || (settings.exportToAax == true && settings.exportDirectory == nil)
        if needsWizard {
            busyMessage = nil
            showWizard = true
            await waitUntilWizardClosed()
            busyMessage = "Initializing …"
        }

        await selectInitialProfile()
        initDone = true
        if profile != nil { await initLibrary() }
        busyMessage = nil

        if settings.autoOpenDownloadDialog, api != nil { showLibrary = true }
    }

    private func waitUntilWizardClosed() async {
        while showWizard { try? await Task.sleep(for: .milliseconds(150)) }
    }

    private func selectInitialProfile() async {
        let profiles = (try? await profileStore.all()) ?? []
        var candidates = profiles
        if let region = settings.profileRegion { candidates = candidates.filter { $0.region == region } }
        if let alias = settings.profileAlias, let acc = store.account(withAlias: alias) {
            candidates = candidates.filter { $0.customerInfo?.accountId == acc.audibleId }
        }
        guard let chosen = candidates.first ?? profiles.first else { return }
        await activate(chosen, refreshToken: settings.autoRefresh)
    }

    /// Makes a profile current: account alias, API client, optional token refresh.
    func activate(_ p: Profile, refreshToken: Bool) async {
        var p = p
        if refreshToken, let refreshed = try? await AudibleAuth(http: http).refreshed(p), refreshed != p {
            p = refreshed
            try? await profileStore.update(p)
        }
        let account = await ensureAccount(for: p)
        profile = p
        accountId = account?.id
        accountAlias = account?.alias
        api = AudibleAPI(profile: p, http: http)
        settings.profileAlias = account?.alias
        settings.profileRegion = p.region
        libraryUpdated = false
        queuedBooks.removeAll()
        selection.removeAll()
    }

    func deactivate() {
        profile = nil
        api = nil
        accountId = nil
        accountAlias = nil
        queuedBooks.removeAll()
        selection.removeAll()
        settings.profileAlias = nil
        settings.profileRegion = nil
    }

    func ensureAccount(for p: Profile) async -> Account? {
        guard let customer = p.customerInfo else { return nil }
        if let acc = store.account(forAudibleId: customer.accountId) { return acc }
        let nextId = (store.accounts.map(\.id).max() ?? 0) + 1
        let alias = await askAlias(
            customerName: customer.name, localId: nextId, currentAlias: nil)
        return store.addAccount(audibleId: customer.accountId, alias: alias ?? "Account \(nextId)")
    }

    func askAlias(customerName: String, localId: Int, currentAlias: String?) async -> String? {
        await withCheckedContinuation { cont in
            aliasRequest = AliasRequest(
                customerName: customerName, localId: localId, currentAlias: currentAlias,
                existing: Set(store.accounts.map(\.alias).filter { $0 != currentAlias }),
                resolve: { [weak self] alias in
                    self?.aliasRequest = nil
                    cont.resume(returning: alias)
                })
        }
    }

    // MARK: - Library

    func initLibrary() async {
        guard api != nil else { return }
        if settings.autoUpdateLibrary && !libraryUpdated {
            busyMessage = "Initializing library …"
            await syncLibrary(resync: false)
            libraryUpdated = true
        }
        await checkFiles()
    }

    func syncLibrary(resync: Bool) async {
        guard let api, let accountId, let region else { return }
        let previous = busyMessage
        busyMessage = "Initializing library …"
        defer { busyMessage = previous }
        do {
            let since = store.sinceLatestPurchaseDate(accountId: accountId, region: region, resync: resync)
            let products = try await api.library(purchasedAfter: since)
            store.merge(products: products, accountId: accountId, region: region, resync: resync)
            busyMessage = "Download cover images …"
            await downloadCovers(api: api)
            rebuildQueue()
        } catch {
            report("Library update failed", error)
        }
    }

    private func downloadCovers(api: AudibleAPI) async {
        let missing = store.books.compactMap { b -> (String, URL)? in
            guard b.coverImageFile == nil || !FileManager.default.fileExists(atPath: store.coverURL(for: b)?.path ?? ""),
                  let s = b.coverImageURL, let u = URL(string: s) else { return nil }
            return (b.asin, u)
        }
        let dir = store.coverDirectory
        await withTaskGroup(of: (String, String)?.self) { group in
            var iterator = missing.makeIterator()
            var running = 0
            func addNext() {
                guard let (asin, url) = iterator.next() else { return }
                running += 1
                group.addTask {
                    guard let data = await api.coverImage(url: url) else { return nil }
                    let name = "\(asin).jpg"
                    do { try data.write(to: dir.appendingPathComponent(name), options: .atomic) } catch { return nil }
                    return (asin, name)
                }
            }
            for _ in 0..<6 { addNext() }
            while let result = await group.next() {
                running -= 1
                if let (asin, name) = result { store.setCoverFile(name, forBook: asin) }
                addNext()
            }
        }
    }

    func checkFiles() async {
        guard !fileCheckAnswered else { return }
        let changes = store.findStateChanges(
            downloadDirectory: settings.downloadDirectory, exportDirectory: settings.exportDirectory)
        guard !changes.isEmpty else { return }
        fileCheckAnswered = true
        let answer = await confirm(
            title: "Some files are missing",
            message: "Some previously downloaded and converted books could not be found at the expected location.\n\nReset the associated conversion state?\n\nYes: reset the state permanently, in the local database.\nNo: keep the database as it is.",
            buttons: ["Yes", "No"])
        if answer == 0 { store.apply(changes) }
    }

    // MARK: - Download list

    func addToQueue(_ asins: [String]) {
        for asin in asins where !queuedBooks.contains(asin) { queuedBooks.append(asin) }
        for row in queueRows where asins.contains(row.ref.bookAsin) { selection.insert(row.id) }
        Task { await fillMetaGaps() }
    }

    func removeFromQueue(books asins: [String]) {
        queuedBooks.removeAll { asins.contains($0) }
        let valid = Set(queueRows.map(\.id))
        selection.formIntersection(valid)
    }

    func removeSelectedFromQueue() {
        let rows = queueRows.filter { selection.contains($0.id) }
        // a book leaves the list when none of its rows stay selected
        let remaining = queueRows.filter { !selection.contains($0.id) }.map(\.ref.bookAsin)
        let toRemove = Set(rows.map(\.ref.bookAsin)).subtracting(remaining)
        removeFromQueue(books: Array(toRemove))
        selection.removeAll()
    }

    func removeAllFromQueue() {
        queuedBooks.removeAll()
        selection.removeAll()
    }

    /// Settings such as multi-part or adult products change which rows exist.
    func rebuildQueue() {
        queuedBooks = queuedBooks.filter { asin in
            guard let b = store.book(asin) else { return false }
            return settings.includeAdultProducts || !(b.adultProduct ?? false)
        }
        let valid = Set(queueRows.map(\.id))
        let newlyAvailable = valid.subtracting(selection)
        _ = newlyAvailable
        selection.formIntersection(valid)
    }

    /// Parts come without runtime/size from the library; fetch what is missing from the catalog.
    private func fillMetaGaps() async {
        guard let api else { return }
        for row in queueRows where row.ref.unitAsin != row.ref.bookAsin && row.duration == 0 {
            if let product = try? await api.product(asin: row.ref.unitAsin) {
                let secs = product.runtime_length_min.map { $0 * 60 }
                store.mutate(row.ref) { u in
                    if u.runtimeSeconds == nil { u.runtimeSeconds = secs }
                    if let sku = product.sku { u.sku = sku }
                    if let lite = product.sku_lite { u.skuLite = lite }
                }
            }
        }
    }

    // MARK: - Running

    func run() {
        guard canRun, let api, let js = settings.jobSettings() else { return }
        let refs = queueRows.filter { selection.contains($0.id) }.map(\.ref)
        guard !refs.isEmpty else { return }

        resetTask?.cancel()
        resetProgress()
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading audiobooks")

        let job = ConversionJob(
            store: store, api: api, settings: js,
            onProgress: { [weak self] event in Task { @MainActor in self?.handle(event) } },
            onChange: { _ in })
        self.job = job
        runTask = Task { [weak self] in
            await job.run(refs)
            guard let self else { return }
            self.finishRun()
        }
    }

    func abort() {
        job?.cancel()
        runTask?.cancel()
    }

    private func finishRun() {
        isRunning = false
        job = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        store.saveNow()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.resetProgress()
        }
    }

    private func resetProgress() {
        downloadFraction = 0
        decryptFraction = 0
        exportFraction = 0
        decryptParts.removeAll()
        exportParts.removeAll()
        itemCount = 0
    }

    private func handle(_ event: ProgressEvent) {
        switch event {
        case .start(let count):
            itemCount = count
            decryptParts.removeAll()
            exportParts.removeAll()
            downloadFraction = 0
            decryptFraction = 0
            exportFraction = 0
        case .nextItem:
            downloadFraction = 0
        case .download(let f):
            downloadFraction = f
        case .decrypt(let ref, let f):
            decryptParts[ref.unitAsin] = f
            decryptFraction = itemCount > 0 ? min(1, decryptParts.values.reduce(0, +) / Double(itemCount)) : 0
        case .export(let ref, let f):
            exportParts[ref.unitAsin] = f
            exportFraction = itemCount > 0 ? min(1, exportParts.values.reduce(0, +) / Double(itemCount)) : 0
        }
    }

    // MARK: - Dialog helpers

    func confirm(title: String, message: String, buttons: [String], style: NSAlert.Style = .informational) async -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        buttons.forEach { alert.addButton(withTitle: $0) }
        if let window = NSApp.keyWindow {
            return await withCheckedContinuation { cont in
                alert.beginSheetModal(for: window) { response in
                    cont.resume(returning: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
                }
            }
        }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func report(_ title: String, _ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Task { _ = await confirm(title: title, message: message, buttons: ["OK"], style: .warning) }
    }

    /// Folder picker; creates `defaultSubPath` under ~/Music when nothing is set yet.
    func chooseFolder(current: String?, defaultSubPath: String, title: String) -> String? {
        var dir = current
        if dir == nil || !FileManager.default.fileExists(atPath: dir!) {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            let d = music.appendingPathComponent(defaultSubPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            dir = d.path
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: dir!)
        panel.message = "Select folder for \(title)"
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return current ?? dir }
        return url.path
    }

    func chooseDownloadFolder() {
        if let p = chooseFolder(current: settings.downloadDirectory, defaultSubPath: "Audible/Download", title: "Download") {
            settings.downloadDirectory = p
        }
    }

    func chooseExportFolder() {
        if let p = chooseFolder(current: settings.exportDirectory, defaultSubPath: "Audible/Export", title: "Export") {
            settings.exportDirectory = p
        }
    }
}
