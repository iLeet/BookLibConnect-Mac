import AppKit
import SwiftUI

@main
struct BookLibConnectApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Book Lib Connect", id: "main") {
            MainView()
                .environment(model)
                .tint(.brand)
                .task { await SnapshotHook.run(model: model) }
        }
        .defaultSize(width: 1040, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Book Lib Connect") { showAbout() }
            }
            CommandGroup(replacing: .help) {
                Button("Book Lib Connect Help") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/iLeet/BookLibConnect-Mac#readme")!)
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("Original Windows version by audiamus") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/audiamus/BookLibConnect")!)
                }
            }
            CommandGroup(after: .newItem) {
                Button("Library …") { model.showLibrary = true }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.api == nil || model.isRunning)
                Button("Profiles …") { model.showProfiles = true }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                    .disabled(model.isRunning)
            }
        }
    }

    private func showAbout() {
        let credits = NSMutableAttributedString(
            string: """
            A native macOS port of Book Lib Connect by audiamus: an Audible downloader and decrypter.

            Books are decrypted with the keys the Audible server issues to your own account, the same way the official player does. This is not DRM circumvention. Use it only for your own audiobooks; do not distribute them.

            Thanks to mkb79 (Audible), Mbucari (AAXClean) and rmcrackan (AudibleApi) for the reference implementations.

            Licensed under the GNU GPL v3.
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "Book Lib Connect",
            .credits: credits,
        ])
    }
}
