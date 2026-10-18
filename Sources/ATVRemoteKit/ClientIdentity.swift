import Foundation
import Security

/// The self-signed RSA client certificate the TV remembers after pairing.
/// Key + certificate live in the Keychain; pairing is tied to this identity, so deleting it
/// means pairing again.
public struct ClientIdentity {
    public let identity: SecIdentity
    public let certificate: SecCertificate

    static let cnPrefix = "atvremote-"
    static let keyTag = Data("co.ubrain.atvremote.clientkey".utf8)

    /// Loads the identity from the Keychain, creating (and storing) a new one on first use.
    /// The CN gets a random suffix: the TV's KeyStoreManager dedupes paired certs by subject, so
    /// two clients (or a re-generated identity) sharing "CN=atvremote" evict each other.
    public static func loadOrCreate() throws -> ClientIdentity {
        if let existing = load() { return existing }
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return try create(commonName: cnPrefix + suffix)
    }

    /// Removes every key and certificate we created, forcing a fresh identity (and pairing).
    /// Deletes item by item: on macOS's file-based keychain a query-wide SecItemDelete only
    /// removes the first match, and certificate labels are replaced by the CN.
    public static func reset() {
        for cert in ourCertificates() {
            SecItemDelete([kSecClass: kSecClassCertificate, kSecValueRef: cert] as CFDictionary)
        }
        while SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: keyTag] as CFDictionary)
                == errSecSuccess {}
    }

    /// The identity is looked up as a whole (cert + key), and its certificate is taken from the
    /// identity itself, so the cert we hash during pairing is exactly the one TLS presents.
    static func load() -> ClientIdentity? {
        var ref: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &ref)
        guard status == errSecSuccess, let identities = ref as? [SecIdentity] else { return nil }
        for identity in identities {
            var cert: SecCertificate?
            if SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert,
               isOurs(cert) {
                return ClientIdentity(identity: identity, certificate: cert)
            }
        }
        return nil
    }

    private static func isOurs(_ cert: SecCertificate) -> Bool {
        (SecCertificateCopySubjectSummary(cert) as String?)?.hasPrefix(cnPrefix) == true
    }

    private static func ourCertificates() -> [SecCertificate] {
        var ref: CFTypeRef?
        SecItemCopyMatching([
            kSecClass: kSecClassCertificate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &ref)
        return ((ref as? [SecCertificate]) ?? []).filter(isOurs)
    }

    static func create(commonName: String) throws -> ClientIdentity {
        reset()
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: keyTag,
            ],
        ] as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error.map { $0.takeRetainedValue() as Error } ?? ATVError.certificate("no public key")
        }

        let der = try SelfSignedCertificate.make(commonName: commonName, publicKeyPKCS1: pkcs1) { tbs in
            guard let sig = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                  tbs as CFData, &error) as Data? else {
                throw error!.takeRetainedValue() as Error
            }
            return sig
        }
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw ATVError.certificate("SecCertificateCreateWithData failed")
        }
        let status = SecItemAdd([
            kSecClass: kSecClassCertificate,
            kSecValueRef: cert,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ATVError.keychain(status)
        }
        guard let identity = load() else {
            throw ATVError.certificate("Keychain did not pair the certificate with its key")
        }
        return identity
    }
}

public enum ATVError: LocalizedError {
    case certificate(String)
    case keychain(OSStatus)
    case connection(String)
    case pairing(String)

    public var errorDescription: String? {
        switch self {
        case .certificate(let m): return "Certificate: \(m)"
        case .keychain(let s): return "Keychain error \(s)"
        case .connection(let m): return "Connection: \(m)"
        case .pairing(let m): return "Pairing: \(m)"
        }
    }
}

/// Minimal DER writer for a self-signed X.509 v3 certificate (sha256WithRSAEncryption).
enum SelfSignedCertificate {
    static func make(commonName: String, publicKeyPKCS1: Data,
                     sign: (Data) throws -> Data) throws -> Data {
        let sha256WithRSA = DER.seq(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]) + DER.null)
        let rsaEncryption = DER.seq(DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) + DER.null)
        let name = DER.seq(DER.set(DER.seq(DER.oid([0x55, 0x04, 0x03]) + DER.utf8(commonName))))
        let now = Date()
        let validity = DER.seq(DER.utcTime(now.addingTimeInterval(-86_400))
                               + DER.utcTime(now.addingTimeInterval(20 * 365 * 86_400)))
        var serial = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        serial[0] &= 0x7F
        let spki = DER.seq(rsaEncryption + DER.bitString(publicKeyPKCS1))
        // Same extensions as androidtvremote2's cert: basicConstraints CA:TRUE pathlen:0 and a
        // dNSName SAN.
        let basicConstraints = DER.seq(DER.oid([0x55, 0x1D, 0x13])
            + DER.tlv(0x04, DER.seq(Data([0x01, 0x01, 0xFF]) + DER.integer(Data([0])))))
        let subjectAltName = DER.seq(DER.oid([0x55, 0x1D, 0x11])
            + DER.tlv(0x04, DER.seq(DER.tlv(0x82, Data(commonName.utf8)))))
        let tbs = DER.seq(
            DER.tlv(0xA0, DER.integer(Data([2])))   // [0] EXPLICIT version v3
            + DER.integer(serial)
            + sha256WithRSA
            + name
            + validity
            + name
            + spki
            + DER.tlv(0xA3, DER.seq(basicConstraints + subjectAltName))  // [3] EXPLICIT extensions
        )
        let signature = try sign(tbs)
        return DER.seq(tbs + sha256WithRSA + DER.bitString(signature))
    }
}

enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let n = content.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var lenBytes = Data()
            var v = n
            while v > 0 { lenBytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
            out.append(0x80 | UInt8(lenBytes.count))
            out.append(lenBytes)
        }
        return out + content
    }

    static func seq(_ c: Data) -> Data { tlv(0x30, c) }
    static func set(_ c: Data) -> Data { tlv(0x31, c) }
    static func oid(_ bytes: [UInt8]) -> Data { tlv(0x06, Data(bytes)) }
    static let null = Data([0x05, 0x00])
    static func utf8(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    static func bitString(_ c: Data) -> Data { tlv(0x03, Data([0]) + c) }

    static func integer(_ bytes: Data) -> Data {
        var b = Data(bytes.drop(while: { $0 == 0 }))
        if b.isEmpty { b = Data([0]) }
        if b.first! & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, b)
    }

    static func utcTime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(f.string(from: date).utf8))
    }

    /// Parses a PKCS#1 RSAPublicKey (SEQUENCE { INTEGER n, INTEGER e }) into unsigned big-endian
    /// modulus and exponent with leading zero bytes stripped.
    static func rsaPublicKey(_ der: Data) -> (modulus: Data, exponent: Data)? {
        var bytes = [UInt8](der)[...]
        func readTLV(expect tag: UInt8) -> ArraySlice<UInt8>? {
            guard bytes.count >= 2, bytes.first == tag else { return nil }
            bytes = bytes.dropFirst()
            var len = Int(bytes.removeFirst())
            if len & 0x80 != 0 {
                let n = len & 0x7F
                guard bytes.count >= n else { return nil }
                len = bytes.prefix(n).reduce(0) { $0 << 8 | Int($1) }
                bytes = bytes.dropFirst(n)
            }
            guard bytes.count >= len else { return nil }
            defer { bytes = bytes.dropFirst(len) }
            return bytes.prefix(len)
        }
        guard let inner = readTLV(expect: 0x30) else { return nil }
        bytes = inner
        guard let n = readTLV(expect: 0x02), let e = readTLV(expect: 0x02) else { return nil }
        return (Data(n.drop(while: { $0 == 0 })), Data(e.drop(while: { $0 == 0 })))
    }

    /// RSA modulus/exponent of a certificate's public key.
    static func rsaPublicKey(of cert: SecCertificate) -> (modulus: Data, exponent: Data)? {
        guard let key = SecCertificateCopyKey(cert),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return rsaPublicKey(der)
    }
}
