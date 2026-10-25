import CryptoKit
import Foundation
import Security
import Testing

@testable import BookLibCore

@Suite struct KeychainTests {
    @Test func keyIsCreatedOnceAndShared() throws {
        let service = "com.booklibconnect.mac.test-\(UUID().uuidString)"
        defer {
            for account in ["configuration-key-open", "configuration-key"] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ] as CFDictionary)
            }
        }
        let a = try KeychainKeyProvider(service: service).key()
        let b = try KeychainKeyProvider(service: service).key()  // a fresh instance reads the stored item
        #expect(a.withUnsafeBytes { Data($0) } == b.withUnsafeBytes { Data($0) })
        #expect(a.bitCount == 256)
    }
}
