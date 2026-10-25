import CryptoKit
import Foundation
import Security

/// Supplies the symmetric key that protects the configuration at rest.
public protocol ConfigKeyProvider: Sendable {
    func key() throws -> SymmetricKey
}

/// Keeps a random 256-bit key in the macOS login Keychain.
///
/// The item is created with an open access list. With the default list the Keychain only trusts the
/// exact binary that created the item, and an app without a stable code-signing identity (a local
/// or ad-hoc build, a new release) is asked for permission again and again. The key still lives in
/// the login Keychain, so it is locked together with the user's session and stays out of the
/// configuration file; it just isn't guarded against other programs running as the same user.
public final class KeychainKeyProvider: ConfigKeyProvider, @unchecked Sendable {
    private let service: String
    private let legacyAccount = "configuration-key"
    private let account = "configuration-key-open"
    private let lock = NSLock()
    private var cached: SymmetricKey?

    public init(service: String = "com.booklibconnect.mac.config") { self.service = service }

    public func key() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let key: SymmetricKey
        if let data = try read(account: account) {
            key = SymmetricKey(data: data)
        } else if let legacy = try read(account: legacyAccount) {
            // Items from earlier builds carry the restrictive default access list; copy the key.
            try add(legacy, account: account)
            SecItemDelete(query(account: legacyAccount) as CFDictionary)
            key = SymmetricKey(data: legacy)
        } else {
            let fresh = SymmetricKey(size: .bits256)
            try add(fresh.withUnsafeBytes { Data($0) }, account: account)
            key = fresh
        }
        cached = key
        return key
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw StoreError.keychain(status) }
        return data
    }

    private func add(_ data: Data, account: String) throws {
        var access: SecAccess?
        var q = query(account: account)
        q[kSecValueData as String] = data
        // trusted-application list of NULL: any application may use the item without a prompt
        if SecAccessCreate("Book Lib Connect configuration key" as CFString, nil, &access) == errSecSuccess,
           let access {
            q[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }
}

public enum StoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case corrupt

    public var errorDescription: String? {
        switch self {
        case .keychain(let s): "Keychain error \(s)"
        case .corrupt: "The stored configuration could not be read."
        }
    }
}

/// Persists registered profiles. By default the file is encrypted with AES-GCM using a
/// Keychain-held key; the user can opt out, mirroring the original "encrypt configuration" switch.
public actor ProfileStore {
    private struct Envelope: Codable {
        var profiles: [Profile]?
        var secure: String?
    }

    private let url: URL
    private let keyProvider: any ConfigKeyProvider
    private var profiles: [Profile] = []
    private var loaded = false
    public private(set) var isEncrypted = true

    public init(directory: URL, keyProvider: any ConfigKeyProvider = KeychainKeyProvider()) {
        self.url = directory.appendingPathComponent("Configuration.json")
        self.keyProvider = keyProvider
    }

    public func all() throws -> [Profile] {
        try loadIfNeeded()
        return profiles.sorted {
            ($0.customerInfo?.accountId ?? "", $0.region) < ($1.customerInfo?.accountId ?? "", $1.region)
        }
    }

    public func profile(matching key: ProfileKey) throws -> Profile? {
        try loadIfNeeded()
        return profiles.first { $0.matches(key) }
    }

    /// Adds or replaces the profile for the same account and region. Returns the replaced profile, if any.
    @discardableResult
    public func addOrReplace(_ profile: Profile) throws -> Profile? {
        try loadIfNeeded()
        var profile = profile
        profile.id = (profiles.map(\.id).max().map { $0 + 1 }) ?? 0
        if let i = profiles.firstIndex(where: { $0.matches(profile.key) }) {
            let prev = profiles[i]
            profiles[i] = profile
            try save()
            return prev
        }
        profiles.append(profile)
        try save()
        return nil
    }

    public func update(_ profile: Profile) throws {
        try loadIfNeeded()
        if let i = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[i] = profile
            try save()
        }
    }

    @discardableResult
    public func remove(_ key: ProfileKey) throws -> Profile? {
        try loadIfNeeded()
        guard let i = profiles.firstIndex(where: { $0.matches(key) }) else { return nil }
        let removed = profiles.remove(at: i)
        try save()
        return removed
    }

    public func setEncrypted(_ encrypted: Bool) throws {
        try loadIfNeeded()
        isEncrypted = encrypted
        try save()
    }

    // MARK: - Persistence

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: url) else { return }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        if let secure = env.secure {
            isEncrypted = true
            guard let blob = Data(base64Encoded: secure) else { throw StoreError.corrupt }
            let box = try AES.GCM.SealedBox(combined: blob)
            let plain = try AES.GCM.open(box, using: try keyProvider.key())
            profiles = try JSONDecoder().decode([Profile].self, from: plain)
        } else {
            isEncrypted = false
            profiles = env.profiles ?? []
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var env = Envelope()
        let json = try JSONEncoder().encode(profiles)
        if isEncrypted {
            let sealed = try AES.GCM.seal(json, using: try keyProvider.key())
            env.secure = sealed.combined?.base64EncodedString()
        } else {
            env.profiles = profiles
        }
        let data = try JSONEncoder().encode(env)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
