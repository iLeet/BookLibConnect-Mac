import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum CryptoError: Error, LocalizedError {
    case invalidKey
    case signingFailed(String)
    case aes(Int32)
    case invalidLicense

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "The device private key could not be read."
        case .signingFailed(let m): "Request signing failed: \(m)"
        case .aes(let s): "AES error \(s)"
        case .invalidLicense: "The license voucher could not be decrypted."
        }
    }
}

public enum Crypto {
    // MARK: AES-128-CBC without padding

    /// Decrypts `data` with AES-128-CBC and no padding. A trailing partial block is not touched
    /// (Audible leaves it unencrypted).
    public static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count)
        let blocks = data.count & ~0xF
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                            keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                            inPtr.baseAddress, blocks,
                            outPtr.baseAddress, blocks, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.aes(status) }
        if blocks < data.count {
            out.replaceSubrange(blocks..<data.count, with: data[data.startIndex.advanced(by: blocks)...])
        }
        return out
    }

    // MARK: License voucher

    /// Decrypts the `license_response` of a content license into key/iv.
    /// See https://patchwork.ffmpeg.org/project/ffmpeg/patch/17559601585196510@sas2-2fa759678732.qloud-c.yandex.net/
    public static func decryptVoucher(
        licenseResponse: String, deviceType: String, deviceSerial: String,
        customerId: String, asin: String
    ) throws -> Voucher {
        let hashable = Data((deviceType + deviceSerial + customerId + asin).utf8)
        let hash = Data(SHA256.hash(data: hashable))
        let key = hash.prefix(16)
        let iv = hash.dropFirst(16).prefix(16)

        guard let encrypted = Data(base64Encoded: licenseResponse) else { throw CryptoError.invalidLicense }
        let plain = try aesCBCDecrypt(encrypted, key: Data(key), iv: Data(iv))
        // plain text is NUL-terminated ASCII JSON
        let json = plain.prefix { $0 != 0 }
        do {
            return try JSONDecoder().decode(Voucher.self, from: Data(json))
        } catch {
            throw CryptoError.invalidLicense
        }
    }

    // MARK: PKCE

    public static func randomURLSafeBytes(_ count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).urlSafeBase64()
    }

    public static func sha256Challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).urlSafeBase64()
    }

    /// 40 random alphanumeric characters, as suggested by the upstream throttling fix.
    public static func randomSerial() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var bytes = [UInt8](repeating: 0, count: 40)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    // MARK: Request signing

    /// SHA256withRSA (PKCS#1 v1.5) signature, base64 encoded.
    public static func rsaSign(_ message: String, privateKeyPEM: String) throws -> String {
        let der = try derFromPEM(privateKeyPEM)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &error) else {
            throw CryptoError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "key import")
        }
        guard let sig = SecKeyCreateSignature(
            key, .rsaSignatureMessagePKCS1v15SHA256, Data(message.utf8) as CFData, &error)
        else {
            throw CryptoError.signingFailed(error?.takeRetainedValue().localizedDescription ?? "sign")
        }
        return (sig as Data).base64EncodedString()
    }

    /// Accepts PKCS#1 (`RSA PRIVATE KEY`) and PKCS#8 (`PRIVATE KEY`) PEM and returns PKCS#1 DER.
    static func derFromPEM(_ pem: String) throws -> Data {
        let lines = pem.split(whereSeparator: \.isNewline).map(String.init)
        let body = lines.filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: body) else { throw CryptoError.invalidKey }
        if pem.contains("BEGIN RSA PRIVATE KEY") { return der }
        return try pkcs1(fromPKCS8: der)
    }

    private static func pkcs1(fromPKCS8 der: Data) throws -> Data {
        var r = DERReader(der)
        guard var seq = r.enter(tag: 0x30) else { throw CryptoError.invalidKey }
        _ = seq.skip(tag: 0x02)  // version
        _ = seq.skip(tag: 0x30)  // algorithm identifier
        guard let octets = seq.read(tag: 0x04) else { throw CryptoError.invalidKey }
        return octets
    }
}

/// Minimal DER walker, just enough to unwrap PKCS#8.
struct DERReader {
    private var data: Data
    init(_ data: Data) { self.data = data }

    private mutating func header(tag: UInt8) -> Int? {
        guard data.count >= 2, data[data.startIndex] == tag else { return nil }
        var idx = data.startIndex + 1
        var len = Int(data[idx])
        idx += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n > 0, n <= 4, data.endIndex - idx >= n else { return nil }
            len = 0
            for _ in 0..<n {
                len = (len << 8) | Int(data[idx])
                idx += 1
            }
        }
        guard data.endIndex - idx >= len else { return nil }
        data = data[idx...]
        return len
    }

    mutating func enter(tag: UInt8) -> DERReader? {
        guard let len = header(tag: tag) else { return nil }
        let inner = data.prefix(len)
        data = data.dropFirst(len)
        return DERReader(Data(inner))
    }

    mutating func read(tag: UInt8) -> Data? {
        guard let len = header(tag: tag) else { return nil }
        let value = data.prefix(len)
        data = data.dropFirst(len)
        return Data(value)
    }

    mutating func skip(tag: UInt8) -> Bool { read(tag: tag) != nil }
}

extension Data {
    func urlSafeBase64() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        var i = 0
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 97...102: c - 87
            case 65...70: c - 55
            default: nil
            }
        }
        while i < chars.count {
            guard let h = nibble(chars[i]), let l = nibble(chars[i + 1]) else { return nil }
            out.append(h << 4 | l)
            i += 2
        }
        self = out
    }
}
