import CryptoKit
import Foundation
import Security

/// Supplies the symmetric key that protects the configuration at rest.
public protocol ConfigKeyProvider: Sendable {
    func key() throws -> SymmetricKey
}

/// Keeps a random 256-bit key in the macOS Keychain.
public struct KeychainKeyProvider: ConfigKeyProvider {
    private let service = "com.booklibconnect.mac.config"
    private let account = "configuration-key"

    public init() {}

    public func key() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else { throw StoreError.keychain(status) }

        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw StoreError.keychain(addStatus) }
        return fresh
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
