import BookLibCore
import SwiftUI

/// First-run setup: profile, download folder, export choice, a pointer to help.
struct WizardView: View {
    @Environment(AppModel.self) private var model

    private enum Step: Hashable { case profile, download, export, help }

    @State private var steps: [Step] = []
    @State private var index = 0
    @State private var profileCreated = false
    @State private var showNewProfile = false
    @State private var loaded = false

    private var step: Step { steps.indices.contains(index) ? steps[index] : .help }
    private var isLast: Bool { index >= steps.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.brand)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading) {
                    Text("Book Lib Connect Setup Wizard").font(.title3.weight(.semibold))
                    Text("Step \(min(index + 1, max(steps.count, 1))) of \(max(steps.count, 1))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            GlassPanel(padding: 20) {
                Group {
                    switch step {
                    case .profile: profilePage
                    case .download: downloadPage
                    case .export: exportPage
                    case .help: helpPage
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            }

            HStack {
                Button("Cancel", role: .cancel) { Task { await cancel() } }
                Spacer()
                Button("Back") { index -= 1 }.disabled(index == 0)
                Button(isLast ? "Finish" : "Next") {
                    if isLast { model.showWizard = false } else { index += 1 }
                }
                .buttonStyle(.glassProminent)
                .tint(.brand)
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdvance)
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(width: 560)
        .background(BrandBackdrop())
        .task {
            guard !loaded else { return }
            loaded = true
            var s: [Step] = []
            let profiles = (try? await model.profileStore.all()) ?? []
            if profiles.isEmpty { s.append(.profile) }
            if model.settings.downloadDirectory == nil { s.append(.download) }
            let exportUndecided = model.settings.exportToAax == nil
                || (model.settings.exportToAax == true && model.settings.exportDirectory == nil)
            if exportUndecided { s.append(.export) }
            s.append(.help)
            steps = s
        }
        .sheet(isPresented: $showNewProfile) {
            NewProfileView { key in profileCreated = key != nil }
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .profile: profileCreated
        case .download: model.settings.downloadDirectory != nil
        case .export:
            model.settings.exportToAax != nil
                && (model.settings.exportToAax == false || model.settings.exportDirectory != nil)
        case .help: true
        }
    }

    private var profilePage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect your Audible account", systemImage: "person.crop.circle.badge.plus").font(.headline)
            Text("Register this Mac as a device on your Audible account. You sign in with your regular web browser, so the app never sees your password.")
                .foregroundStyle(.secondary)
            HStack {
                Button(profileCreated ? "Profile created" : "New Profile …") { showNewProfile = true }
                    .buttonStyle(.glass)
                    .disabled(profileCreated)
                if profileCreated { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
    }

    private var downloadPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Download folder", systemImage: "arrow.down.circle").font(.headline)
            Text("Books are downloaded and converted to .m4b here.").foregroundStyle(.secondary)
            HStack {
                Button("Choose …") { model.chooseDownloadFolder() }.buttonStyle(.glass)
                Text(model.settings.downloadDirectory ?? "Not set")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var exportPage: some View {
        @Bindable var s = model.settings
        return VStack(alignment: .leading, spacing: 12) {
            Label("Export for AAX Audio Converter", systemImage: "square.and.arrow.up").font(.headline)
            Text("Optionally export finished books as .aax files, with chapter information, for AAX Audio Converter. No activation code is needed.")
                .foregroundStyle(.secondary)
            Picker("Export", selection: Binding(
                get: { s.exportToAax },
                set: { s.exportToAax = $0 })
            ) {
                Text("Do not export").tag(Bool?.some(false))
                Text("Export as .aax").tag(Bool?.some(true))
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if s.exportToAax == true {
                HStack {
                    Button("Choose …") { model.chooseExportFolder() }.buttonStyle(.glass)
                    Text(s.exportDirectory ?? "Not set")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    private var helpPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("You’re all set", systemImage: "checkmark.seal.fill").font(.headline)
            Text("Choose “Download …” to pick books from your library, select them in the list, and press Run.")
                .foregroundStyle(.secondary)
            Link("Open the user guide", destination: URL(string: "https://github.com/iLeet/BookLibConnect-Mac#readme")!)
        }
    }

    private func cancel() async {
        _ = await model.confirm(
            title: "Setup aborted",
            message: "Initial setup aborted.\n\nMake the remaining settings via the main window.",
            buttons: ["OK"], style: .warning)
        model.showWizard = false
    }
}
