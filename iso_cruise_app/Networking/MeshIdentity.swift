import CryptoKit
import Foundation

/// This phone's mesh identity: a signing key and a key-agreement key.
///
/// The public id *is* a fingerprint of the signing key (see `id(for:)`), so nobody can
/// claim someone else's id without their private key: every packet is signed, and a
/// packet whose key doesn't hash to its sender id is dropped. That closes the hole that
/// let attackers impersonate users in earlier mesh messengers (Bridgefy, bitchat), where
/// ids and keys were only loosely tied together.
///
/// Kept in the Keychain for a few hours (`IdentityStore`) and then replaced, so a
/// phone can't be followed by its id for long.
nonisolated struct MeshIdentity: Sendable {
    let signingKey: Curve25519.Signing.PrivateKey
    let agreementKey: Curve25519.KeyAgreement.PrivateKey

    init() {
        signingKey = Curve25519.Signing.PrivateKey()
        agreementKey = Curve25519.KeyAgreement.PrivateKey()
    }

    init?(signing: Data, agreement: Data) {
        guard let signingKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: signing),
              let agreementKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreement)
        else { return nil }
        self.signingKey = signingKey
        self.agreementKey = agreementKey
    }

    var id: String { Self.id(for: signingKey.publicKey.rawRepresentation) }
    var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
    var agreementPublicKey: Data { agreementKey.publicKey.rawRepresentation }

    /// The id for a signing public key: 16 bytes of its SHA-256, as 32 lowercase hex characters.
    static func id(for signingPublicKey: Data) -> String {
        SHA256.hash(data: Data("cruiselan.id.v2|".utf8) + signingPublicKey)
            .prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidId(_ id: String) -> Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    func sign(_ data: Data) -> Data? {
        try? signingKey.signature(for: data)
    }

    /// The symmetric key this phone shares with another identity. Both sides derive the
    /// same key from their own private key and the other's public key; relays can't.
    func pairKey(with otherId: String, agreementPublicKey: Data) -> SymmetricKey? {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: agreementPublicKey),
              let secret = try? agreementKey.sharedSecretFromKeyAgreement(with: publicKey)
        else { return nil }
        let pair = [id, otherId].sorted().joined(separator: "|")
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("cruiselan.mesh.v1".utf8),
                                              sharedInfo: Data(pair.utf8), outputByteCount: 32)
    }
}
