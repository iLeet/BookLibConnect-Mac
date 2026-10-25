import AppKit
import BookLibCore
import SwiftUI

// MARK: - Manage profiles

struct ManageProfilesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable, Hashable {
        var id: UInt32
        var key: ProfileKey
        var alias: String
        var tag: String { "\(alias); \(key.region.rawValue)" }
    }

    @State private var entries: [Entry] = []
    @State private var selected: UInt32?
    @State private var encrypt = true
    @State private var showNew = false
    @State private var aliasChanged = false

    private var current: Entry? { entries.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Manage Profiles").font(.title3.weight(.semibold))

            GlassPanel(title: "Profile") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Profile", selection: $selected) {
                        Text("—").tag(UInt32?.none)
                        ForEach(entries) { Text($0.tag).tag(Optional($0.id)) }
                    }
                    .labelsHidden()

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            Text("Account").foregroundStyle(.secondary)
                            Text(current?.key.accountName ?? "")
                        }
                        GridRow {
                            Text("Device").foregroundStyle(.secondary)
                            Text(current?.key.deviceName ?? "")
                        }
                    }
                    .font(.callout)

                    HStack {
                        Button("Add …") { showNew = true }
                        Button("Rename …") { Task { await rename() } }.disabled(current == nil)
                        Button("Remove") { Task { await remove() } }.disabled(current == nil)
                    }
                    .buttonStyle(.glass)
                }
            }

            Toggle("Encrypt configuration", isOn: $encrypt)
                .toggleStyle(.checkbox)
                .help("Keeps device keys encrypted at rest, with a key held in the macOS Keychain.")
                .onChange(of: encrypt) { _, on in
                    if !on { Task { await confirmUnencrypted() } }
                }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { Task { await finish(apply: false) } }
                Button("OK") { Task { await finish(apply: true) } }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .keyboardShortcut(.defaultAction)
                    .disabled(current == nil)
            }
            .buttonStyle(.glass)
        }
        .padding(22)
        .frame(width: 520)
        .background(BrandBackdrop())
        .task { await load() }
        .sheet(isPresented: $showNew) {
            NewProfileView { key in
                Task {
                    await load()
                    if let key { selected = entries.first { $0.key.matches(key) }?.id }
                }
            }
        }
    }

    private func load() async {
        encrypt = await model.profileStore.isEncrypted
        let all = (try? await model.profileStore.all()) ?? []
        entries = all.map { p in
            let alias = model.store.account(forAudibleId: p.customerInfo?.accountId ?? "")?.alias
                ?? p.customerInfo?.name ?? "Account"
            return Entry(id: p.id, key: p.key, alias: alias)
        }
        if selected == nil || !entries.contains(where: { $0.id == selected }) {
            selected = entries.first { $0.key.matches(model.profile?.key ?? ProfileKey(id: 0, region: .us, accountId: "-", accountName: "", deviceName: "")) }?.id
                ?? entries.first?.id
        }
    }

    private func rename() async {
        guard let entry = current, let account = model.store.account(forAudibleId: entry.key.accountId) else { return }
        if let alias = await model.askAlias(
            customerName: entry.key.accountName, localId: account.id, currentAlias: account.alias),
           alias != account.alias {
            model.store.setAlias(alias, forAccount: account.id)
            aliasChanged = true
            await load()
        }
    }

    private func remove() async {
        guard let entry = current else { return }
        let key = entry.key
        let answer = await model.confirm(
            title: "Remove Profile",
            message: "Remove profile for\nregion/domain “\(key.region.rawValue)”,\naccount “\(key.accountName)”?\n\nAssociated device “\(key.deviceName)” should be deregistered via Amazon account management.",
            buttons: ["Remove", "Cancel"], style: .warning)
        guard answer == 0 else { return }
        do {
            try await model.profileStore.remove(key)
            if model.profile?.matches(key) == true { model.deactivate() }
            await load()
            _ = await model.confirm(
                title: "Remove Profile",
                message: "Profile removed.\n\nAssociated device “\(key.deviceName)” should be deregistered via Amazon account management.",
                buttons: ["OK"])
        } catch {
            model.report("Remove profile failed", error)
        }
    }

    private func confirmUnencrypted() async {
        let answer = await model.confirm(
            title: "Store configuration unencrypted?",
            message: "Unencrypted configuration data is a security risk!\n\nLeave the configuration encrypted unless you know exactly what you are doing.\n\nSave as unencrypted, plain text, are you sure?",
            buttons: ["Keep encrypted", "Save unencrypted"], style: .critical)
        if answer == 0 { encrypt = true }
    }

    private func finish(apply: Bool) async {
        guard apply else {
            if aliasChanged, let p = model.profile { await model.activate(p, refreshToken: false) }
            dismiss()
            return
        }
        if encrypt != (await model.profileStore.isEncrypted) {
            try? await model.profileStore.setEncrypted(encrypt)
        }
        if let entry = current, let profile = try? await model.profileStore.profile(matching: entry.key) {
            let changed = model.profile?.matches(entry.key) != true || model.profile?.id != profile.id
            if changed || aliasChanged {
                await model.activate(profile, refreshToken: changed && model.settings.autoRefresh)
                if changed { await model.initLibrary() }
            }
        }
        dismiss()
    }
}

// MARK: - New profile

struct NewProfileView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onDone: (ProfileKey?) -> Void

    @State private var region: Region?
    @State private var preAmazon = false
    @State private var login: PendingLogin?
    @State private var loginURL = ""
    @State private var finalURL = ""
    @State private var working = false
    @State private var result: ProfileKey?
    @State private var existingNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.title3.weight(.semibold))

            GlassPanel(title: "1 · Region") {
                HStack {
                    Picker("Region / domain", selection: $region) {
                        Text("Select …").tag(Region?.none)
                        ForEach(Region.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(result != nil)

                    Toggle("Pre-Amazon account", isOn: $preAmazon)
                        .toggleStyle(.checkbox)
                        .disabled(!(region?.allowsPreAmazonAccount ?? false) || result != nil)
                        .help("Legacy Audible username sign-in, only for DE, UK and US.")
                }
            }

            GlassPanel(title: "2 · Sign-in link") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sign in with your regular web browser. This app never sees your credentials.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Create URL") { createURL() }
                            .disabled(region == nil || result != nil || login != nil)
                        TextField("Login URL", text: $loginURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Open in Browser") {
                            if let u = login?.url { NSWorkspace.shared.open(u) }
                        }
                        .disabled(login == nil)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(loginURL, forType: .string)
                        }
                        .disabled(login == nil)
                    }
                    .buttonStyle(.glass)
                    if let existingNote {
                        Label(existingNote, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            GlassPanel(title: "3 · Paste the final URL") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("After signing in, the browser lands on a “page not found”. Copy that page’s address and paste it here.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://www.amazon.…/ap/maplanding?…", text: $finalURL)
                            .textFieldStyle(.roundedBorder)
                            .disabled(login == nil || result != nil || working)
                            .onSubmit { Task { await register() } }
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                finalURL = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                Task { await register() }
                            }
                        }
                        .buttonStyle(.glass)
                        .disabled(login == nil || result != nil || working)
                        if working { ProgressView().controlSize(.small) }
                    }
                    if let result {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow { Text("Region").foregroundStyle(.secondary); Text(result.region.displayName) }
                            GridRow { Text("Account").foregroundStyle(.secondary); Text(result.accountName) }
                            GridRow { Text("Device").foregroundStyle(.secondary); Text(result.deviceName) }
                        }
                        .font(.callout)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone(nil); dismiss() }
                    .buttonStyle(.glass)
                Button("OK") { onDone(result); dismiss() }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil)
            }
        }
        .padding(22)
        .frame(width: 700)
        .background(BrandBackdrop())
        .onChange(of: region) { _, new in
            login = nil
            loginURL = ""
            finalURL = ""
            if !(new?.allowsPreAmazonAccount ?? false) { preAmazon = false }
            existingNote = nil
        }
        .onChange(of: preAmazon) { _, _ in
            login = nil
            loginURL = ""
        }
        .onChange(of: finalURL) { _, new in
            // pasting the landing URL is enough, no need to press return
            if new.contains("openid.oa2.authorization_code"), !working, result == nil {
                Task { await register() }
            }
        }
    }

    private func createURL() {
        guard let region else { return }
        Task {
            let existing = ((try? await model.profileStore.all()) ?? []).filter { $0.region == region }
            if !existing.isEmpty {
                let names = existing.compactMap { $0.customerInfo?.name }.joined(separator: ", ")
                existingNote = "A profile already exists for \(region.rawValue) and account\(existing.count > 1 ? "s" : "") “\(names)”. Signing in with the same account overwrites it."
            }
        }
        do {
            let l = try AudibleLogin.begin(region: region, preAmazon: preAmazon && region.allowsPreAmazonAccount)
            login = l
            loginURL = l.url.absoluteString
        } catch {
            model.report("Could not create the sign-in link", error)
        }
    }

    private func register() async {
        guard let login, !working else { return }
        guard let url = URL(string: finalURL.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil else {
            _ = await model.confirm(title: "Invalid URL", message: "Invalid URL.\nPlease try again.", buttons: ["OK"], style: .warning)
            return
        }
        guard let code = AudibleLogin.authorizationCode(from: url) else {
            _ = await model.confirm(title: "Authorization failed", message: "Authorization failed.\nPlease try again.", buttons: ["OK"], style: .warning)
            return
        }
        working = true
        defer { working = false }
        do {
            var profile = try await AudibleAuth(http: model.http).register(login, authorizationCode: code)
            let previous = try await model.profileStore.addOrReplace(profile)
            profile = (try await model.profileStore.profile(matching: profile.key)) ?? profile
            result = profile.key
            var message = "Success. New profile created.\nRegion / domain: “\(profile.region.rawValue)”\nAccount: \(profile.key.accountName)\nDevice: “\(profile.key.deviceName)”"
            if let prev = previous {
                message = "New profile created.\nRegion / domain: “\(profile.region.rawValue)”\nAccount: \(profile.key.accountName)\nDevice: “\(profile.key.deviceName)”\n\nThe previous device “\(prev.deviceInfo.name)” should be deregistered via Amazon account management."
            }
            _ = await model.confirm(title: "New Profile", message: message, buttons: ["OK"])
        } catch {
            model.report("Device registration failed", error)
        }
    }
}

// MARK: - Account alias

struct AliasView: View {
    let request: AliasRequest
    @State private var text = ""

    private var isRenaming: Bool { request.currentAlias != nil }
    private var valid: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && !request.existing.contains(t)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account alias for “\(request.customerName)”").font(.title3.weight(.semibold))
            Text("The alias identifies this account in the app, without showing the Audible account name.")
                .font(.callout).foregroundStyle(.secondary)

            HStack {
                TextField("Alias", text: $text)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    Button(request.currentAlias ?? "Account \(request.localId)") {
                        text = request.currentAlias ?? "Account \(request.localId)"
                    }
                    Button(request.customerName) { text = request.customerName }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .fixedSize()
            }
            if !text.isEmpty && !valid {
                Text(request.existing.contains(text.trimmingCharacters(in: .whitespaces))
                     ? "This alias is already in use." : "Use at least 3 characters.")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                if isRenaming {
                    Button("Cancel", role: .cancel) { request.resolve(nil) }.buttonStyle(.glass)
                }
                Button("OK") { request.resolve(text.trimmingCharacters(in: .whitespaces)) }
                    .buttonStyle(.glassProminent)
                    .tint(.brand)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(BrandBackdrop())
        .onAppear { text = request.currentAlias ?? "Account \(request.localId)" }
    }
}
