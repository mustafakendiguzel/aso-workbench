import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import ASOCore

/// Signs JWTs with an EC P-256 private key (Apple's `.p8` / PEM format).
public struct ES256Signer: Sendable {
    private let key: P256.Signing.PrivateKey

    /// Accepts PKCS#8 ("BEGIN PRIVATE KEY") and SEC1 ("BEGIN EC PRIVATE KEY") PEM text.
    public init(pem: String) throws {
        let cleaned = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: cleaned)
        } catch {
            throw ASOError.invalidInput("The private key is not a valid P-256 PEM key: \(error.localizedDescription)")
        }
    }

    /// First 16 hex characters of SHA-256 over the DER SubjectPublicKeyInfo of the matching public key.
    /// Same value as `openssl pkey -pubout -outform DER | shasum -a 256`, so it can be compared with the key uploaded to Apple.
    public var publicKeyFingerprint: String {
        let digest = SHA256.hash(data: key.publicKey.derRepresentation)
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    public func sign(header: [String: Any], payload: [String: Any]) throws -> String {
        let h = try Self.b64url(JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        let p = try Self.b64url(JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        let signingInput = Data((h + "." + p).utf8)
        let signature = try key.signature(for: signingInput)
        return h + "." + p + "." + Self.b64url(signature.rawRepresentation)
    }

    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
