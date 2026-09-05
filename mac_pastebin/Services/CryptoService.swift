import CryptoKit
import Foundation

struct EncryptedPayload: Equatable {
    let nonce: Data
    let ciphertext: Data
    let authenticationTag: Data
}

struct CryptoService {
    enum CryptoServiceError: Error {
        case tamperedDataAccepted
    }

    func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> EncryptedPayload {
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        let nonceData = sealedBox.nonce.withUnsafeBytes { Data($0) }

        return EncryptedPayload(
            nonce: nonceData,
            ciphertext: sealedBox.ciphertext,
            authenticationTag: sealedBox.tag
        )
    }

    func decrypt(_ payload: EncryptedPayload, using key: SymmetricKey) throws -> Data {
        let nonce = try AES.GCM.Nonce(data: payload.nonce)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: payload.ciphertext,
            tag: payload.authenticationTag
        )

        return try AES.GCM.open(sealedBox, using: key)
    }

    #if DEBUG
    static func runSelfCheck() throws {
        let service = CryptoService()
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data([0x43, 0x72, 0x79, 0x70, 0x74, 0x6f])

        let encrypted = try service.encrypt(plaintext, using: key)
        let decrypted = try service.decrypt(encrypted, using: key)
        precondition(decrypted == plaintext, "CryptoService round-trip failed")
        
        var tamperedCiphertext = [UInt8](encrypted.ciphertext)
        precondition(!tamperedCiphertext.isEmpty, "CryptoService self-check expected ciphertext bytes")
        tamperedCiphertext[0] ^= 0x01
        let tampered = EncryptedPayload(
            nonce: encrypted.nonce,
            ciphertext: Data(tamperedCiphertext),
            authenticationTag: encrypted.authenticationTag
        )

        do {
            _ = try service.decrypt(tampered, using: key)
            throw CryptoServiceError.tamperedDataAccepted
        } catch CryptoServiceError.tamperedDataAccepted {
            throw CryptoServiceError.tamperedDataAccepted
        } catch {
            // Expected: AES-GCM authentication should reject tampered data.
        }
    }
    #endif
}
