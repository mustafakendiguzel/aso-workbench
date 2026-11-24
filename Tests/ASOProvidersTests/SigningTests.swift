import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Testing
@testable import ASOProviders
import ASOCore

/// Pins the signing and hashing primitives to known values, so CryptoKit (Apple) and swift-crypto (Linux, Windows)
/// are proven to produce the same tokens and checksums.
@Suite("Signing and hashing")
struct SigningTests {
    // Throwaway key generated for the tests only, in PKCS#8 and SEC1 form.
    static let pkcs8PEM = """
    -----BEGIN PRIVATE KEY-----
    MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
    OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
    1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
    -----END PRIVATE KEY-----
    """
    static let sec1PEM = """
    -----BEGIN EC PRIVATE KEY-----
    MHcCAQEEIHr2cy9YHQBa/PIW9jhf9jcQKSQsxghA3X0qelUDt9IcoAoGCCqGSM49
    AwEHoUQDQgAEEVs/o5+uQbTjL3chynL4wXgUg2R9q9UU8I5mEovUf86QZ7kOBIjJ
    wqnzD1omageEHWwHdBO6B+dFabmdT9POxg==
    -----END EC PRIVATE KEY-----
    """
    static let publicPEM = """
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEEVs/o5+uQbTjL3chynL4wXgUg2R9
    q9UU8I5mEovUf86QZ7kOBIjJwqnzD1omageEHWwHdBO6B+dFabmdT9POxg==
    -----END PUBLIC KEY-----
    """

    static func base64URLDecode(_ s: Substring) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    @Test("A signed JWT verifies against the matching public key")
    func jwtSignatureVerifies() throws {
        let jwt = try ES256Signer(pem: Self.pkcs8PEM).sign(header: ["alg": "ES256", "kid": "K"], payload: ["iss": "I", "exp": 1])
        let parts = jwt.split(separator: ".")
        try #require(parts.count == 3)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Self.base64URLDecode(parts[2])))
        let publicKey = try P256.Signing.PublicKey(pemRepresentation: Self.publicPEM)
        #expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))

        let header = try JSONSerialization.jsonObject(with: try #require(Self.base64URLDecode(parts[0]))) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "K")
    }

    @Test("Fingerprint matches `openssl pkey -pubout -outform DER | sha256` for PKCS#8 and SEC1 keys")
    func publicKeyFingerprint() throws {
        #expect(try ES256Signer(pem: Self.pkcs8PEM).publicKeyFingerprint == "a40f0f2e2974dc76")
        #expect(try ES256Signer(pem: Self.sec1PEM).publicKeyFingerprint == "a40f0f2e2974dc76")
    }

    @Test("Surrounding whitespace is ignored, a broken key is a typed error")
    func pemInput() throws {
        _ = try ES256Signer(pem: "\n  " + Self.pkcs8PEM + "\n\n")
        #expect(throws: ASOError.self) { try ES256Signer(pem: "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----") }
    }

    @Test("Base64URL has no padding and no + or /")
    func base64URL() {
        #expect(ES256Signer.b64url(Data([0xfb, 0xff])) == "-_8")
        #expect(ES256Signer.b64url(Data("a".utf8)) == "YQ")
    }

    @Test("Screenshot checksum is the lowercase MD5 hex App Store Connect expects")
    func md5Checksum() {
        #expect(ASCMetadataProvider.md5Hex(Data()) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(ASCMetadataProvider.md5Hex(Data("abc".utf8)) == "900150983cd24fb0d6963f7d28e17f72")
    }
}
