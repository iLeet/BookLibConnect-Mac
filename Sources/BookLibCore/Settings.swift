import Foundation
import Observation

/// What a conversion run needs to know, frozen at the time the user presses Run.
public struct JobSettings: Sendable {
    public var downloadDirectory: String
    public var exportDirectory: String?
    public var exportToAax: Bool
    public var multiPartDownload: Bool
    public var downloadQuality: DownloadQuality
    public var keepEncryptedFiles: Bool

    public init(
        downloadDirectory: String, exportDirectory: String?, exportToAax: Bool,
        multiPartDownload: Bool, downloadQuality: DownloadQuality, keepEncryptedFiles: Bool
    ) {
        self.downloadDirectory = downloadDirectory
        self.exportDirectory = exportDirectory
        self.exportToAax = exportToAax
        self.multiPartDownload = multiPartDownload
        self.downloadQuality = downloadQuality
        self.keepEncryptedFiles = keepEncryptedFiles
    }
}

/// User-facing options of the main window, persisted in `UserDefaults`.
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    public var autoRefresh: Bool { didSet { defaults.set(autoRefresh, forKey: "autoRefresh") } }
    public var autoUpdateLibrary: Bool { didSet { defaults.set(autoUpdateLibrary, forKey: "autoUpdateLibrary") } }
    public var autoOpenDownloadDialog: Bool {
        didSet { defaults.set(autoOpenDownloadDialog, forKey: "autoOpenDownloadDialog") }
    }
    public var multiPartDownload: Bool { didSet { defaults.set(multiPartDownload, forKey: "multiPartDownload") } }
    public var includeAdultProducts: Bool {
        didSet { defaults.set(includeAdultProducts, forKey: "includeAdultProducts") }
    }
    public var hideUnavailableProducts: Bool {
        didSet { defaults.set(hideUnavailableProducts, forKey: "hideUnavailableProducts") }
    }
    public var keepEncryptedFiles: Bool { didSet { defaults.set(keepEncryptedFiles, forKey: "keepEncryptedFiles") } }
    public var downloadQuality: DownloadQuality {
        didSet { defaults.set(downloadQuality.reduced.rawValue, forKey: "downloadQuality") }
    }
    public var initialSorting: InitialSorting {
        didSet { defaults.set(initialSorting.rawValue, forKey: "initialSorting") }
    }
    public var downloadDirectory: String? { didSet { defaults.set(downloadDirectory, forKey: "downloadDirectory") } }
    public var exportDirectory: String? { didSet { defaults.set(exportDirectory, forKey: "exportDirectory") } }
    /// `nil` until the user decided (drives the setup wizard).
    public var exportToAax: Bool? {
        didSet {
            if let exportToAax { defaults.set(exportToAax, forKey: "exportToAax") } else {
                defaults.removeObject(forKey: "exportToAax")
            }
        }
    }
    public var profileAlias: String? { didSet { defaults.set(profileAlias, forKey: "profileAlias") } }
    public var profileRegion: Region? { didSet { defaults.set(profileRegion?.rawValue, forKey: "profileRegion") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        autoRefresh = bool("autoRefresh", false)
        autoUpdateLibrary = bool("autoUpdateLibrary", true)
        autoOpenDownloadDialog = bool("autoOpenDownloadDialog", false)
        multiPartDownload = bool("multiPartDownload", false)
        includeAdultProducts = bool("includeAdultProducts", false)
        hideUnavailableProducts = bool("hideUnavailableProducts", false)
        keepEncryptedFiles = bool("keepEncryptedFiles", false)
        downloadQuality = DownloadQuality(rawValue: defaults.object(forKey: "downloadQuality") as? Int ?? 2) ?? .high
        initialSorting = InitialSorting(rawValue: defaults.integer(forKey: "initialSorting")) ?? .stateDate
        downloadDirectory = defaults.string(forKey: "downloadDirectory")
        exportDirectory = defaults.string(forKey: "exportDirectory")
        exportToAax = defaults.object(forKey: "exportToAax") as? Bool
        profileAlias = defaults.string(forKey: "profileAlias")
        profileRegion = defaults.string(forKey: "profileRegion").flatMap(Region.init(rawValue:))
    }

    public func jobSettings() -> JobSettings? {
        guard let dir = downloadDirectory else { return nil }
        return JobSettings(
            downloadDirectory: dir, exportDirectory: exportDirectory, exportToAax: exportToAax ?? false,
            multiPartDownload: multiPartDownload, downloadQuality: downloadQuality.reduced,
            keepEncryptedFiles: keepEncryptedFiles)
    }
}
