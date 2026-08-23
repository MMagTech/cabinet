import CryptoKit
import Foundation
import Security

/// Pairing a phone to a television, so the phone may drive a game.
///
/// The design is docs/scope-phone-controller-pairing.md: pair once with a
/// short code shown on the television, store a shared secret on both
/// sides, and from then on every packet carries proof of that secret.
/// This file is the shared half, compiled into both apps. The television
/// and the phone each keep their own UI and wiring.
///
/// The code on screen is short enough to type in seconds, so it cannot
/// be the secret itself. Instead each side makes a one-time key pair and
/// the two swap public halves, which gives both a strong shared value
/// nothing listening on the network can compute. The typed code then
/// proves a person could see the television: the phone's proof mixes the
/// agreed value with the code, the television checks it, and three wrong
/// tries kill the code. The stored secret is derived from both, so a
/// recording of the whole exchange is worthless without the private
/// halves that never left either device.
///
/// The honest limit, accepted in the design doc's spirit of naming
/// boundaries: an attacker actively rewriting traffic between the two
/// devices during the one-time pairing itself could insert themselves.
/// Beating that needs a PAKE, which CryptoKit does not ship and this
/// project will not hand-roll. Every packet after pairing is safe
/// against recording, replay and forgery alike.
enum ControllerPairing {
    /// The television's master switch, "Allow a phone as a controller".
    /// Off by default, and while it is off the television never binds a
    /// socket: to the network the feature does not exist. Only the tvOS
    /// app reads this; it lives here because the rest of pairing does.
    static let allowKey = "com.mmagtech.RommAppTV.allowPhoneController"

    // MARK: Identity

    /// This device's stable name on the link, eight random bytes made
    /// once and kept. Not a secret, it only says which stored pairing to
    /// look up, the way a serial number names a controller without
    /// unlocking anything. The secret it points at lives in the
    /// Keychain.
    static var deviceID: Data {
        let key = "com.mmagtech.RommApp.controllerLinkID"
        if let hex = UserDefaults.standard.string(forKey: key),
           let existing = Data(hexString: hex), existing.count == 8 {
            return existing
        }
        let fresh = randomBytes(8)
        UserDefaults.standard.set(fresh.hexString, forKey: key)
        return fresh
    }

    // MARK: The stored secret

    /// One Keychain entry per paired device, keyed by the other side's
    /// deviceID. Deliberately its own service, not a second account
    /// under the RomM token's: Keychain.swift documents itself as
    /// holding the token and nothing else, and that stays true.
    private static let service = "com.mmagtech.RommApp.controllerPairing"

    static func secret(forPeer peer: Data) -> SymmetricKey? {
        var lookup = query(peer: peer)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    static func savePairing(secret: SymmetricKey, forPeer peer: Data) throws {
        let data = secret.withUnsafeBytes { Data($0) }
        SecItemDelete(query(peer: peer) as CFDictionary)
        var attributes = query(peer: peer)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairingError.keychain(status) }
    }

    static func forgetPairing(forPeer peer: Data) {
        SecItemDelete(query(peer: peer) as CFDictionary)
    }

    /// Whether this device has ever completed a pairing. Home shows
    /// its TV Controller row only when this is true, so someone with
    /// no Apple TV never sees the feature at all; the first pairing
    /// starts from Settings instead.
    static var hasAnyPairing: Bool {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(lookup as CFDictionary, nil) == errSecSuccess
    }

    private static func query(peer: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peer.hexString,
        ]
    }

    enum PairingError: Error {
        case keychain(OSStatus)
    }

    // MARK: Derivation

    /// Every key this exchange produces comes through here: the agreed
    /// value, the challenge's salt, the typed code and a label saying
    /// which of the three keys is wanted. Distinct labels mean the proof
    /// key, the acknowledgement key and the stored secret can never be
    /// confused for one another even though they share ingredients.
    private static func derived(_ ecdh: SharedSecret, salt: Data, code: String, label: String) -> SymmetricKey {
        ecdh.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("cabinet-pair-\(label)-v1|\(code)".utf8),
            outputByteCount: 32
        )
    }

    /// What both sides sign: every public value the exchange used, in a
    /// fixed order, so a proof cannot be replayed into a different
    /// exchange with so much as one byte swapped.
    private static func transcript(phonePub: Data, tvPub: Data, phoneID: Data, tvID: Data, salt: Data) -> Data {
        phonePub + tvPub + phoneID + tvID + salt
    }

    // MARK: The session, and proof on every packet

    /// A pairing is forever; a session is one conversation. Each join
    /// mixes the stored secret with a fresh nonce from each side, so a
    /// recording of last night's packets proves nothing about tonight,
    /// and a phone that reconnects gets a clean replay window instead
    /// of inheriting an old one.

    /// Authenticates the television's hello before a session exists.
    /// Keyed by the phone's nonce alone, because the hello is the
    /// packet that delivers the television's, and it must not be
    /// forgeable by anything that merely watched the join go past.
    static func helloKey(secret: SymmetricKey, phoneNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: phoneNonce,
                               info: Data("cabinet-hello-v1".utf8), outputByteCount: 32)
    }

    /// The key every packet in one session proves itself with.
    static func sessionKey(secret: SymmetricKey, phoneNonce: Data, tvNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, salt: phoneNonce + tvNonce,
                               info: Data("cabinet-session-v1".utf8), outputByteCount: 32)
    }

    /// Eight bytes of a full HMAC. Forging one is a shot in eight bytes
    /// of dark per packet, with nothing reusable learned from a miss;
    /// next to a ten byte header, thirty two would be all tax.
    static let tagLength = 8

    /// The context string keeps directions apart: a packet proven for
    /// one direction can never double as proof in the other.
    static func tag(key: SymmetricKey, context: String, bytes: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(context.utf8) + bytes, using: key))
            .prefix(tagLength)
    }

    /// Constant time on the comparison, so a wrong tag reveals nothing
    /// about how wrong it was.
    static func validTag(_ candidate: Data, key: SymmetricKey, context: String, bytes: Data) -> Bool {
        guard candidate.count == tagLength else { return false }
        let expected = tag(key: key, context: context, bytes: bytes)
        var diff: UInt8 = 0
        for (a, b) in zip(expected, candidate) { diff |= a ^ b }
        return diff == 0
    }

    static func makeCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String(format: "%06u", UInt32.random(in: 0..<1_000_000, using: &rng))
    }

    /// "417209" reads better as "417 209", everywhere a code is shown.
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    static func randomBytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed")
        return data
    }

    // MARK: Television side

    /// One pairing attempt as the television sees it: born when an
    /// unknown phone asks, dead on success, three wrong codes, or
    /// abandonment. Holds the one-time private key, so the whole attempt
    /// dies with it and nothing about a failed try survives to be
    /// probed.
    final class Acceptor {
        let phoneID: Data
        let phonePub: Data
        let code: String
        let salt: Data
        let startedAt = Date()
        private(set) var triesLeft = 3
        private let tvID: Data
        private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        /// UDP retries mean the same proof can arrive twice. A repeat of
        /// the last wrong proof gets the same verdict again rather than
        /// burning a second try for one typo.
        private var lastWrongProof: Data?

        init?(phoneID: Data, phonePub: Data, tvID: Data) {
            guard phoneID.count == 8, phonePub.count == 32,
                  (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePub)) != nil
            else { return nil }
            self.phoneID = phoneID
            self.phonePub = phonePub
            self.tvID = tvID
            self.code = ControllerPairing.makeCode()
            self.salt = ControllerPairing.randomBytes(16)
        }

        /// The reply to the phone's request: who this television is, its
        /// public half, and the salt. Resent as-is if the request comes
        /// again, so retries converge on one exchange.
        var challengePayload: Data {
            tvID + ephemeral.publicKey.rawRepresentation + salt
        }

        enum Verdict {
            case success(secret: SymmetricKey, ack: Data)
            case wrong(triesLeft: Int)
            case cancelled
        }

        func verify(proof: Data) -> Verdict {
            if proof == lastWrongProof { return .wrong(triesLeft: triesLeft) }
            guard let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePub),
                  let ecdh = try? ephemeral.sharedSecretFromKeyAgreement(with: pub)
            else { return .cancelled }
            let transcript = ControllerPairing.transcript(
                phonePub: phonePub, tvPub: ephemeral.publicKey.rawRepresentation,
                phoneID: phoneID, tvID: tvID, salt: salt
            )
            let confirmKey = ControllerPairing.derived(ecdh, salt: salt, code: code, label: "confirm")
            if HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: transcript, using: confirmKey) {
                let ackKey = ControllerPairing.derived(ecdh, salt: salt, code: code, label: "ack")
                let ack = Data(HMAC<SHA256>.authenticationCode(for: transcript, using: ackKey))
                let secret = ControllerPairing.derived(ecdh, salt: salt, code: code, label: "secret")
                return .success(secret: secret, ack: ack)
            }
            lastWrongProof = proof
            triesLeft -= 1
            return triesLeft <= 0 ? .cancelled : .wrong(triesLeft: triesLeft)
        }
    }

    // MARK: Phone side

    /// One pairing attempt as the phone sees it. Same lifetime rule as
    /// the Acceptor: the one-time private key never outlives the
    /// attempt.
    final class Requester {
        let phoneID: Data
        private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        private(set) var tvID: Data?
        private var tvPub: Data?
        private var salt: Data?
        /// The code behind the last proof sent, kept so the
        /// television's acknowledgement can be checked against the same
        /// ingredients. A valid acknowledgement proves the television
        /// knew the code too, so a wrong pairing is never stored.
        private var codeTried: String?

        init(phoneID: Data) {
            self.phoneID = phoneID
        }

        var requestPayload: Data {
            phoneID + ephemeral.publicKey.rawRepresentation
        }

        /// Takes the television's challenge apart. False means the bytes
        /// were not a challenge, and the attempt should be abandoned
        /// rather than negotiated with.
        func acceptChallenge(_ payload: Data) -> Bool {
            guard payload.count == 8 + 32 + 16 else { return false }
            let pub = Data(payload.dropFirst(8).prefix(32))
            guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub)) != nil else { return false }
            tvID = Data(payload.prefix(8))
            tvPub = pub
            salt = Data(payload.suffix(16))
            return true
        }

        /// The proof for one typed code, or nil before a challenge has
        /// arrived. Computing it never consumes a try; only the
        /// television judges.
        func proof(code: String) -> Data? {
            guard let tvID, let tvPub, let salt,
                  let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: tvPub),
                  let ecdh = try? ephemeral.sharedSecretFromKeyAgreement(with: pub)
            else { return nil }
            codeTried = code
            let transcript = ControllerPairing.transcript(
                phonePub: ephemeral.publicKey.rawRepresentation, tvPub: tvPub,
                phoneID: phoneID, tvID: tvID, salt: salt
            )
            let confirmKey = ControllerPairing.derived(ecdh, salt: salt, code: code, label: "confirm")
            return Data(HMAC<SHA256>.authenticationCode(for: transcript, using: confirmKey))
        }

        /// Checks the television's acknowledgement and, only if it holds
        /// up, returns the secret to store. Nil means the
        /// acknowledgement was not genuine and nothing should be kept.
        func acceptSuccess(_ ack: Data) -> SymmetricKey? {
            guard let tvID, let tvPub, let salt, let codeTried,
                  let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: tvPub),
                  let ecdh = try? ephemeral.sharedSecretFromKeyAgreement(with: pub)
            else { return nil }
            let transcript = ControllerPairing.transcript(
                phonePub: ephemeral.publicKey.rawRepresentation, tvPub: tvPub,
                phoneID: phoneID, tvID: tvID, salt: salt
            )
            let ackKey = ControllerPairing.derived(ecdh, salt: salt, code: codeTried, label: "ack")
            guard HMAC<SHA256>.isValidAuthenticationCode(ack, authenticating: transcript, using: ackKey) else {
                return nil
            }
            return ControllerPairing.derived(ecdh, salt: salt, code: codeTried, label: "secret")
        }
    }
}

// MARK: - Hex

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
