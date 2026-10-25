import CommonCrypto
import CryptoKit
import Foundation
import Security
import Testing

@testable import BookLibCore

@Suite struct CryptoTests {
    static func makeRSAKey() throws -> (priv: SecKey, pub: SecKey, pkcs1: Data) {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var err: Unmanaged<CFError>?
        let priv = try #require(SecKeyCreateRandomKey(attrs as CFDictionary, &err))
        let pub = try #require(SecKeyCopyPublicKey(priv))
        let der = try #require(SecKeyCopyExternalRepresentation(priv, &err)) as Data
        return (priv, pub, der)
    }

    static func pem(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }

    static func wrapPKCS8(_ pkcs1: Data) -> Data {
        func len(_ n: Int) -> [UInt8] {
            n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        }
        let alg: [UInt8] = [0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00]
        let octet = [0x04] + len(pkcs1.count) + [UInt8](pkcs1)
        let inner: [UInt8] = [0x02, 0x01, 0x00] + alg + octet
        return Data([0x30] + len(inner.count) + inner)
    }

    @Test func signsWithPKCS1Key() throws {
        let k = try Self.makeRSAKey()
        let sig = try Crypto.rsaSign("hello", privateKeyPEM: Self.pem(k.pkcs1, label: "RSA PRIVATE KEY"))
        let data = try #require(Data(base64Encoded: sig))
        var err: Unmanaged<CFError>?
        #expect(SecKeyVerifySignature(
            k.pub, .rsaSignatureMessagePKCS1v15SHA256, Data("hello".utf8) as CFData, data as CFData, &err))
        #expect(!SecKeyVerifySignature(
            k.pub, .rsaSignatureMessagePKCS1v15SHA256, Data("hellO".utf8) as CFData, data as CFData, &err))
    }

    @Test func signsWithPKCS8Key() throws {
        let k = try Self.makeRSAKey()
        let pem = Self.pem(Self.wrapPKCS8(k.pkcs1), label: "PRIVATE KEY")
        let sig = try Crypto.rsaSign("hello", privateKeyPEM: pem)
        var err: Unmanaged<CFError>?
        #expect(SecKeyVerifySignature(
            k.pub, .rsaSignatureMessagePKCS1v15SHA256, Data("hello".utf8) as CFData,
            Data(base64Encoded: sig)! as CFData, &err))
    }

    @Test func signatureHeadersFollowTheDocumentedFormat() throws {
        let k = try Self.makeRSAKey()
        let now = Date(timeIntervalSince1970: 1_700_000_123)  // 2023-11-14T22:15:23Z
        let h = try AudibleAPI.signatureHeaders(
            method: "GET", relativeURL: "/1.0/library?x=1", body: "", adpToken: "TOKEN",
            privateKeyPEM: Self.pem(k.pkcs1, label: "RSA PRIVATE KEY"), now: now)
        #expect(h["x-adp-token"] == "TOKEN")
        #expect(h["x-adp-alg"] == "SHA256withRSA:1.0")
        let parts = try #require(h["x-adp-signature"]).split(separator: ":", maxSplits: 1).map(String.init)
        // rounded down to 10 minutes: 22:10:00
        #expect(parts[1] == "2023-11-14T22:10:00Z")
        var err: Unmanaged<CFError>?
        let signed = "GET\n/1.0/library?x=1\n2023-11-14T22:10:00Z\n\nTOKEN"
        #expect(SecKeyVerifySignature(
            k.pub, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData,
            Data(base64Encoded: parts[0])! as CFData, &err))
    }

    @Test func voucherRoundTrip() throws {
        let type = "A2CZJZGLK2JJVM", serial = "SERIAL123", customer = "amzn1.account.X", asin = "B00TEST"
        let hash = Data(SHA256.hash(data: Data((type + serial + customer + asin).utf8)))
        let key = hash.prefix(16), iv = hash.dropFirst(16).prefix(16)

        var plain = Data(#"{"key":"00112233445566778899aabbccddeeff","iv":"ffeeddccbbaa99887766554433221100","rules":[]}"#.utf8)
        plain.append(contentsOf: [UInt8](repeating: 0, count: 16 - plain.count % 16))  // NUL padding
        var cipher = Data(count: plain.count)
        var moved = 0
        let st = cipher.withUnsafeMutableBytes { c in
            plain.withUnsafeBytes { p in
                Data(key).withUnsafeBytes { k in
                    Data(iv).withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, k.baseAddress, 16,
                                v.baseAddress, p.baseAddress, plain.count, c.baseAddress, plain.count, &moved)
                    }
                }
            }
        }
        #expect(st == kCCSuccess)

        let v = try Crypto.decryptVoucher(
            licenseResponse: cipher.base64EncodedString(), deviceType: type, deviceSerial: serial,
            customerId: customer, asin: asin)
        #expect(v.key == "00112233445566778899aabbccddeeff")
        #expect(v.iv == "ffeeddccbbaa99887766554433221100")

        #expect(throws: CryptoError.self) {
            _ = try Crypto.decryptVoucher(
                licenseResponse: cipher.base64EncodedString(), deviceType: type, deviceSerial: serial,
                customerId: customer, asin: "OTHER")
        }
    }

    @Test func pkceChallengeMatchesRFC7636() {
        #expect(Crypto.sha256Challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test func serialsAndVerifiersAreWellFormed() {
        let s = Crypto.randomSerial()
        #expect(s.count == 40)
        #expect(s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let v = Crypto.randomURLSafeBytes(32)
        #expect(v.count == 43)
        #expect(!v.contains("=") && !v.contains("+") && !v.contains("/"))
    }

    @Test func hexRoundTrip() {
        let d = Data([0, 1, 0xAB, 0xFF])
        #expect(d.hexString == "0001abff")
        #expect(Data(hexString: "0001ABff") == d)
        #expect(Data(hexString: "abc") == nil)
    }
}

@Suite struct LoginTests {
    @Test func buildsAmazonLoginURL() throws {
        let login = try AudibleLogin.begin(region: .us, preAmazon: false)
        let comps = try #require(URLComponents(url: login.url, resolvingAgainstBaseURL: false))
        #expect(comps.host == "www.amazon.com")
        #expect(comps.path == "/ap/signin")
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(q["openid.return_to"] == "https://www.amazon.com/ap/maplanding")
        #expect(q["openid.assoc_handle"] == "amzn_audible_ios_us")
        #expect(q["marketPlaceId"] == "AF2M0KC94RCEA")
        #expect(q["openid.oa2.client_id"] == "device:" + AudibleLogin.clientId(serial: login.serial))
        #expect(q["openid.oa2.code_challenge"] == Crypto.sha256Challenge(for: login.codeVerifier))
        #expect(q["openid.oa2.code_challenge_method"] == "S256")
    }

    @Test func buildsLegacyLoginURLOnlyWhereSupported() throws {
        let uk = try AudibleLogin.begin(region: .uk, preAmazon: true)
        #expect(uk.url.host == "www.audible.co.uk")
        #expect(throws: AudibleError.self) { _ = try AudibleLogin.begin(region: .fr, preAmazon: true) }
    }

    @Test func extractsAuthorizationCode() {
        let u = URL(string: "https://www.amazon.com/ap/maplanding?openid.oa2.authorization_code=ABC123&x=y")!
        #expect(AudibleLogin.authorizationCode(from: u) == "ABC123")
        #expect(AudibleLogin.authorizationCode(from: URL(string: "https://www.amazon.com/ap/maplanding")!) == nil)
    }

    @Test func clientIdIsHexOfSerialAndDeviceType() {
        #expect(AudibleLogin.clientId(serial: "AB") == Data("AB#A2CZJZGLK2JJVM".utf8).hexString)
    }
}

@Suite struct DateTests {
    @Test func xmlTimeMatchesDotNetFormat() {
        #expect(DateParsing.xmlString(Date(timeIntervalSince1970: 0)) == "1970-01-01T00:00:00Z")
        #expect(DateParsing.xmlString(Date(timeIntervalSince1970: 0.001)) == "1970-01-01T00:00:00.001Z")
        #expect(DateParsing.xmlString(Date(timeIntervalSince1970: 0.120)) == "1970-01-01T00:00:00.12Z")
    }

    @Test func parsesAudibleDates() {
        #expect(DateParsing.parse("2021-03-01T14:22:33.123Z") != nil)
        #expect(DateParsing.parse("2021-03-01T14:22:33Z") != nil)
        #expect(DateParsing.parse("2008-01-04") != nil)
        #expect(DateParsing.parse("nonsense") == nil)
    }
}
