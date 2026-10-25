import BookLibCore
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder: [KeyPathComparator<QueueRow>] = []

    var body: some View {
        @Bindable var model = model
        ZStack {
            BrandBackdrop()

            VStack(spacing: 14) {
                SettingsRow()
                    .disabled(model.isRunning)

                HStack(spacing: 10) {
                    Button("Download …") { model.showLibrary = true }
                        .disabled(model.api == nil || model.isRunning)
                    Button("Remove") { model.removeSelectedFromQueue() }
                        .disabled(model.selection.isEmpty || model.isRunning)
                    Spacer()
                }
                .buttonStyle(.glass)
                .controlSize(.large)

                QueueTable(sortOrder: $sortOrder)

                RunPanel()
            }
            .padding(16)
            .disabled(model.busyMessage != nil)

            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .sheet(isPresented: $model.showLibrary) {
            LibraryView()
        }
        .sheet(isPresented: $model.showProfiles) {
            ManageProfilesView()
        }
        .sheet(isPresented: $model.showWizard) {
            WizardView()
                .interactiveDismissDisabled()
        }
        .sheet(item: $model.aliasRequest) { request in
            AliasView(request: request)
                .interactiveDismissDisabled()
        }
        .task { await model.bootstrap() }
        .onChange(of: model.settings.multiPartDownload) { model.rebuildQueue() }
        .onChange(of: model.settings.includeAdultProducts) { model.rebuildQueue() }
    }
}

// MARK: - Settings

private struct SettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ProfilePanel().frame(width: 190)
                DownloadPanel()
                ExportPanel().frame(width: 210)
            }
        }
    }
}

private struct ProfilePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel(title: "Profile settings") {
            VStack(alignment: .leading, spacing: 8) {
                if let alias = model.accountAlias, let region = model.region {
                    Label("\(alias) · \(region.rawValue.uppercased())", systemImage: "person.crop.circle")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No profile").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Profiles …") { model.showProfiles = true }
                    .buttonStyle(.glass)
                    .disabled(model.isRunning)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct DownloadPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        GlassPanel(title: "Download settings") {
            Grid(alignment: .leading, horizontalSpacing: 26, verticalSpacing: 7) {
                GridRow {
                    Toggle("Auto connect", isOn: $s.autoRefresh)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Audio download quality").font(.caption).foregroundStyle(.secondary)
                        Picker("Audio download quality", selection: $s.downloadQuality) {
                            Text("Normal").tag(DownloadQuality.normal)
                            Text("High").tag(DownloadQuality.high)
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Initial sorting").font(.caption).foregroundStyle(.secondary)
                        Picker("Initial sorting", selection: $s.initialSorting) {
                            ForEach(InitialSorting.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                GridRow {
                    Toggle("Auto update book lib", isOn: $s.autoUpdateLibrary)
                    Toggle("Multi-part download", isOn: $s.multiPartDownload)
                    Toggle("Hide unavailable", isOn: $s.hideUnavailableProducts)
                }
                GridRow {
                    Toggle("Auto open download", isOn: $s.autoOpenDownloadDialog)
                    Toggle("Adult products", isOn: $s.includeAdultProducts)
                    Button("Download Folder …") { model.chooseDownloadFolder() }
                        .buttonStyle(.glass)
                        .help(s.downloadDirectory ?? "No folder selected")
                }
                GridRow {
                    Toggle("Keep encrypted files", isOn: $s.keepEncryptedFiles)
                    Color.clear.frame(height: 1)
                    Color.clear.frame(height: 1)
                }
            }
            .toggleStyle(.checkbox)
        }
        .onChange(of: s.autoRefresh) { _, on in
            guard on, let p = model.profile else { return }
            Task { await model.activate(p, refreshToken: true) }
        }
        .onChange(of: s.autoUpdateLibrary) { _, on in
            guard on else { return }
            Task { await model.initLibrary() }
        }
    }
}

private struct ExportPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel(title: "Export settings") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(
                    "Export as .aax",
                    isOn: Binding(
                        get: { model.settings.exportToAax ?? false },
                        set: { model.settings.exportToAax = $0 }))
                    .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Button("Export Folder …") { model.chooseExportFolder() }
                    .buttonStyle(.glass)
                    .help(model.settings.exportDirectory ?? "No folder selected")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - Queue

private struct QueueTable: View {
    @Environment(AppModel.self) private var model
    @Binding var sortOrder: [KeyPathComparator<QueueRow>]

    var body: some View {
        @Bindable var model = model
        let rows = model.queueRows.sorted(using: sortOrder)
        Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("State", value: \.state.rawValue) { StateIcon(state: $0.state) }
                .width(52)
            TableColumn("Title", value: \.title) { Text($0.title).lineLimit(1) }
                .width(min: 140, ideal: 220)
            TableColumn("Author", value: \.author) { Text($0.author).lineLimit(1) }
                .width(min: 80, ideal: 110)
            TableColumn("File size", value: \.fileSize) { Text(Fmt.size($0.fileSize)).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Duration", value: \.duration) { Text(Fmt.duration($0.duration)).monospacedDigit() }
                .width(min: 70, ideal: 80)
            TableColumn("Year", value: \.year) { Text(Fmt.year($0.year)).monospacedDigit() }
                .width(min: 48, ideal: 54)
            TableColumn("Narrator", value: \.narrator) { Text($0.narrator).lineLimit(1) }
                .width(min: 80, ideal: 100)
            TableColumn("Sample rate", value: \.sampleRate) { Text(Fmt.hz($0.sampleRate)).monospacedDigit() }
                .width(min: 80, ideal: 90)
            TableColumn("Bit rate", value: \.bitRate) { Text(Fmt.kbps($0.bitRate)).monospacedDigit() }
                .width(min: 70, ideal: 80)
        }
        .scrollContentBackground(.hidden)
        .clipShape(.rect(cornerRadius: 22))
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to download yet", systemImage: "books.vertical")
                } description: {
                    Text(model.api == nil
                         ? "Add a profile to connect to your Audible account."
                         : "Choose “Download …” to pick books from your library.")
                }
                .allowsHitTesting(false)
            }
        }
        .disabled(model.isRunning)
    }
}

// MARK: - Run

private struct RunPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GlassPanel(padding: 16) {
            HStack(spacing: 18) {
                Button {
                    model.run()
                } label: {
                    Text("Run").font(.title3.weight(.semibold)).frame(width: 74, height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canRun)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        Text("Download")
                        ProgressView(value: model.downloadFraction)
                    }
                    GridRow {
                        Text("Decrypt")
                        ProgressView(value: model.decryptFraction)
                    }
                    GridRow {
                        Text("Export")
                        ProgressView(value: model.exportFraction)
                    }
                }
                .frame(maxWidth: .infinity)

                Button("Abort") { model.abort() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(!model.isRunning)
                    .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}

// MARK: - Busy

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.12)).ignoresSafeArea()
            HStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                Text(message).font(.headline)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .transition(.opacity)
    }
}
