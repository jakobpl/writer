import CommonCrypto
import CryptoKit
import Foundation
import Security

struct KeyDerivationMetadata: Equatable {
    enum Algorithm: String {
        case pbkdf2HMACSHA256 = "PBKDF2-HMAC-SHA256"
    }

    let algorithm: Algorithm
    let salt: Data
    let iterations: UInt32
    let keyLength: Int
}

enum VaultPasswordPolicy {
    static let minimumCharacterCount = 12
    static let requirementText = "Use at least 12 characters. A long, unique passphrase works best."
    private static let legacyCommonlyGuessedPassword = String(
        decoding: [119, 114, 105, 116, 101, 114, 119, 114, 105, 116, 101, 114],
        as: UTF8.self
    )

    enum ValidationError: Error, Equatable {
        case tooShort
        case commonlyGuessed
    }

    static func validate(_ password: String) throws {
        guard password.count >= minimumCharacterCount else {
            throw ValidationError.tooShort
        }

        let normalized = password
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let commonlyGuessedPasswords: Set<String> = [
            "123456789012",
            "correcthorsebatterystaple",
            "letmeinletmein",
            "password1234",
            "passwordpassword",
            "qwertyqwerty",
            "mac_pastebinmac_pastebin",
            Self.legacyCommonlyGuessedPassword
        ]
        guard !commonlyGuessedPasswords.contains(normalized),
              Set(normalized).count > 1
        else {
            throw ValidationError.commonlyGuessed
        }
    }

    static func isAcceptable(_ password: String) -> Bool {
        (try? validate(password)) != nil
    }
}

struct KeyDerivationService {
    enum KeyDerivationError: Error {
        case emptyPassword
        case invalidMetadata
        case randomSaltGenerationFailed
        case keyDerivationFailed
        case deterministicDerivationFailed
        case saltSeparationFailed
        case wrongPasswordAccepted
    }

    static let defaultSaltByteCount = 16
    static let defaultIterationCount: UInt32 = 600_000
    static let defaultKeyByteCount = 32
    static let maximumSaltByteCount = 64
    static let maximumIterationCount: UInt32 = 2_000_000

    func makeMetadata(
        iterations: UInt32 = defaultIterationCount,
        keyLength: Int = defaultKeyByteCount
    ) throws -> KeyDerivationMetadata {
        try KeyDerivationMetadata(
            algorithm: .pbkdf2HMACSHA256,
            salt: randomData(byteCount: Self.defaultSaltByteCount),
            iterations: iterations,
            keyLength: keyLength
        )
    }

    func deriveKey(from password: String, metadata: KeyDerivationMetadata) throws -> SymmetricKey {
        SymmetricKey(data: try deriveKeyData(from: password, metadata: metadata))
    }

    private func deriveKeyData(from password: String, metadata: KeyDerivationMetadata) throws -> Data {
        guard !password.isEmpty else {
            throw KeyDerivationError.emptyPassword
        }

        guard metadata.algorithm == .pbkdf2HMACSHA256,
              (Self.defaultSaltByteCount...Self.maximumSaltByteCount).contains(metadata.salt.count),
              (1...Self.maximumIterationCount).contains(metadata.iterations),
              metadata.keyLength == Self.defaultKeyByteCount
        else {
            throw KeyDerivationError.invalidMetadata
        }

        var passwordData = Data(password.utf8)
        defer {
            passwordData.resetBytes(in: passwordData.indices)
        }

        var derivedKey = Data(count: metadata.keyLength)
        let status = derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            metadata.salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        passwordData.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        metadata.salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        metadata.iterations,
                        derivedKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                        metadata.keyLength
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw KeyDerivationError.keyDerivationFailed
        }

        return derivedKey
    }

    private func randomData(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, bytes.bindMemory(to: UInt8.self).baseAddress!)
        }

        guard status == errSecSuccess else {
            throw KeyDerivationError.randomSaltGenerationFailed
        }

        return data
    }

    #if DEBUG
    static func runSelfCheck() throws {
        let service = KeyDerivationService()
        let cryptoService = CryptoService()
        let password = UUID().uuidString
        let wrongPassword = UUID().uuidString
        let metadata = try service.makeMetadata()
        let sameMetadata = KeyDerivationMetadata(
            algorithm: metadata.algorithm,
            salt: metadata.salt,
            iterations: metadata.iterations,
            keyLength: metadata.keyLength
        )
        let differentSaltMetadata = try service.makeMetadata(
            iterations: metadata.iterations,
            keyLength: metadata.keyLength
        )

        let firstKeyData = try service.deriveKeyData(from: password, metadata: metadata)
        let secondKeyData = try service.deriveKeyData(from: password, metadata: sameMetadata)
        guard firstKeyData == secondKeyData else {
            throw KeyDerivationError.deterministicDerivationFailed
        }

        let differentSaltKeyData = try service.deriveKeyData(from: password, metadata: differentSaltMetadata)
        guard firstKeyData != differentSaltKeyData else {
            throw KeyDerivationError.saltSeparationFailed
        }

        let correctKey = try service.deriveKey(from: password, metadata: metadata)
        let wrongKey = try service.deriveKey(from: wrongPassword, metadata: metadata)
        let plaintext = Data([0x4b, 0x44, 0x46, 0x20, 0x63, 0x68, 0x65, 0x63, 0x6b])
        let encrypted = try cryptoService.encrypt(plaintext, using: correctKey)
        let decrypted = try cryptoService.decrypt(encrypted, using: correctKey)
        precondition(decrypted == plaintext, "KeyDerivationService round-trip failed")

        do {
            _ = try cryptoService.decrypt(encrypted, using: wrongKey)
            throw KeyDerivationError.wrongPasswordAccepted
        } catch KeyDerivationError.wrongPasswordAccepted {
            throw KeyDerivationError.wrongPasswordAccepted
        } catch {
            // Expected: the wrong password-derived key should fail AES-GCM authentication.
        }
    }
    #endif
}
