import AppKit
import SwiftUI

/// Developer aid: with `BLC_SNAPSHOT_DIR` set (usually together with `BLC_DEMO=1`) the app walks
/// through its main screens and writes a PNG of each window, then quits.
@MainActor
enum SnapshotHook {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["BLC_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func run(model: AppModel) async {
        guard let dir = directory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2.5))
        shoot("main", dir)

        model.showLibrary = true
        try? await Task.sleep(for: .seconds(1.5))
        shoot("library", dir)
        model.showLibrary = false
        try? await Task.sleep(for: .seconds(0.8))

        model.showProfiles = true
        try? await Task.sleep(for: .seconds(1.2))
        shoot("profiles", dir)
        model.showProfiles = false
        try? await Task.sleep(for: .seconds(0.8))

        model.showWizard = true
        try? await Task.sleep(for: .seconds(1.2))
        shoot("wizard", dir)
        model.showWizard = false
        try? await Task.sleep(for: .seconds(0.5))

        if ProcessInfo.processInfo.environment["BLC_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
    }

    private static func shoot(_ name: String, _ dir: URL) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            guard let rep else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent("\(name)-\(i).png"))
            }
        }
    }
}
