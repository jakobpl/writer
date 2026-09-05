import AppKit
import CryptoKit
import Foundation

struct VaultService {
    enum VaultServiceError: Error {
        case missingVault
        case invalidVault
        case invalidKeyDerivationMetadata
        case unlockFailed
        case missingDerivedKey
        case archivedVaultNotFound
    }

    struct VaultUnlockResult {
        let key: SymmetricKey
        let payload: VaultPayload
    }

    struct ArchivedVault: Identifiable, Equatable {
        let id: String
        let fileName: String
        let modifiedAt: Date
        let byteCount: Int64
    }

    private let fileManager: FileManager
    private let keyDerivationService: KeyDerivationService
    private let cryptoService: CryptoService
    private let applicationSupportDirectoryOverride: URL?
    private let newVaultIterationCount: UInt32
    private static let vaultDirectoryName = "mac_pastebin"
    private static let vaultFileName = "vault.mac_pastebin"
    private static let legacyVaultDirectoryName = String(
        decoding: [87, 114, 105, 116, 101, 114],
        as: UTF8.self
    )
    private static let legacyVaultFileName = String(
        decoding: [118, 97, 117, 108, 116, 46, 119, 114, 105, 116, 101, 114],
        as: UTF8.self
    )
    private static let archiveReasons = ["archived", "corrupt", "migration"]
    private static let currentVaultFormatVersion = 2
    private static let currentPayloadFormatVersion = 2
    private static let validationPayloadPlaintext = Data([
        0x57, 0x72, 0x69, 0x74, 0x65, 0x72, 0x20, 0x76,
        0x61, 0x75, 0x6c, 0x74, 0x20, 0x76, 0x31
    ])

    init(
        fileManager: FileManager = .default,
        keyDerivationService: KeyDerivationService = KeyDerivationService(),
        cryptoService: CryptoService = CryptoService(),
        applicationSupportDirectory: URL? = nil,
        newVaultIterationCount: UInt32 = KeyDerivationService.defaultIterationCount
    ) {
        self.fileManager = fileManager
        self.keyDerivationService = keyDerivationService
        self.cryptoService = cryptoService
        applicationSupportDirectoryOverride = applicationSupportDirectory
        self.newVaultIterationCount = newVaultIterationCount
    }

    var applicationSupportDirectory: URL {
        get throws {
            if let applicationSupportDirectoryOverride {
                return applicationSupportDirectoryOverride
            }
            return try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        }
    }

    var vaultDirectoryURL: URL {
        get throws {
            let applicationSupportDirectory = try applicationSupportDirectory
            let currentDirectory = applicationSupportDirectory.appendingPathComponent(
                Self.vaultDirectoryName,
                isDirectory: true
            )
            let legacyDirectory = applicationSupportDirectory.appendingPathComponent(
                Self.legacyVaultDirectoryName,
                isDirectory: true
            )
            try migrateLegacyVaultIfNeeded(from: legacyDirectory, to: currentDirectory)
            return currentDirectory
        }
    }

    var vaultFileURL: URL {
        get throws {
            try vaultDirectoryURL
                .appendingPathComponent(Self.vaultFileName, isDirectory: false)
        }
    }

    func vaultDirectoryExists() -> Bool {
        guard let url = try? vaultDirectoryURL else {
            return false
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func vaultFileExists() -> Bool {
        guard let url = try? vaultFileURL else {
            return false
        }

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    func ensureVaultDirectoryExists() throws {
        let directoryURL = try vaultDirectoryURL

        if !vaultDirectoryExists() {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    func createVaultIfNeeded() throws {
        try ensureVaultDirectoryExists()

        let fileURL = try vaultFileURL
        if !vaultFileExists() || isEmptyFile(at: fileURL) {
            try writeVaultFile(makeNewVaultFile(), to: fileURL)
        }
    }

    func loadVaultFile() throws -> VaultFile? {
        guard vaultFileExists() else {
            return nil
        }

        let fileURL = try vaultFileURL
        _ = try VaultResourcePolicy.validatedFileSize(at: fileURL, fileManager: fileManager)
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard data.count <= VaultResourcePolicy.maximumVaultFileBytes else {
            throw VaultServiceError.invalidVault
        }
        return try Self.decoder.decode(VaultFile.self, from: data)
    }

    func vaultNeedsCreation() -> Bool {
        guard vaultFileExists() else {
            return true
        }

        guard let vaultFile = try? loadVaultFile() else {
            return false
        }

        return vaultFile.encryptedPayload.isEmptyPlaceholder
    }

    func createVault(password: String) throws -> VaultUnlockResult {
        try ensureVaultDirectoryExists()
        try VaultPasswordPolicy.validate(password)

        let metadata = try keyDerivationService.makeMetadata(iterations: newVaultIterationCount)
        let key = try keyDerivationService.deriveKey(from: password, metadata: metadata)
        let payload = VaultPayload.singleEditorNote(body: "")
        let payloadData = try encodePayload(payload)
        let encryptedPayload = try cryptoService.encrypt(
            payloadData,
            using: key
        )
        let vaultFile = VaultFile(
            formatVersion: Self.currentVaultFormatVersion,
            createdAt: Date(),
            keyDerivation: VaultKeyDerivationMetadata(metadata: metadata),
            encryption: .aes256GCM,
            payloadEncoding: VaultPayloadEncoding.binaryPropertyList,
            encryptedPayload: VaultEncryptedPayload(payload: encryptedPayload)
        )

        try writeVaultFile(vaultFile, to: try vaultFileURL)
        return VaultUnlockResult(key: key, payload: payload)
    }

    func unlockVault(password: String) throws -> VaultUnlockResult {
        let vaultFile: VaultFile?
        do {
            vaultFile = try loadVaultFile()
        } catch {
            throw VaultServiceError.invalidVault
        }

        guard let vaultFile else {
            throw VaultServiceError.missingVault
        }

        guard isSupportedVaultFile(vaultFile) else {
            throw VaultServiceError.invalidVault
        }

        guard let metadata = keyDerivationMetadata(from: vaultFile.keyDerivation) else {
            throw VaultServiceError.invalidKeyDerivationMetadata
        }

        guard let encryptedPayload = vaultFile.encryptedPayload.encryptedPayload(),
              !vaultFile.encryptedPayload.isEmptyPlaceholder
        else {
            throw VaultServiceError.invalidVault
        }

        let key = try keyDerivationService.deriveKey(from: password, metadata: metadata)
        let decrypted = try cryptoService.decrypt(encryptedPayload, using: key)
        guard decrypted.count <= VaultResourcePolicy.maximumPlaintextBytes else {
            throw VaultServiceError.invalidVault
        }

        if decrypted == Self.validationPayloadPlaintext {
            return VaultUnlockResult(key: key, payload: .singleEditorNote(body: ""))
        }

        if let payload = decodePayload(decrypted, for: vaultFile) {
            guard (1...Self.currentPayloadFormatVersion).contains(payload.formatVersion),
                  isValidPayload(payload)
            else {
                throw VaultServiceError.invalidVault
            }
            return VaultUnlockResult(key: key, payload: payload)
        }

        if vaultFile.payloadEncoding == VaultPayloadEncoding.binaryPropertyList
            || decrypted.first(where: { !$0.isASCIIWhitespace }) == 0x7B {
            throw VaultServiceError.invalidVault
        }

        guard decrypted.count <= VaultResourcePolicy.maximumBodyBytesPerNote,
              let editorText = String(data: decrypted, encoding: .utf8)
        else {
            throw VaultServiceError.unlockFailed
        }

        return VaultUnlockResult(key: key, payload: .singleEditorNote(body: editorText))
    }

    func moveCurrentVaultAsideForReplacement() throws -> URL {
        guard vaultFileExists() else {
            throw VaultServiceError.missingVault
        }

        let fileURL = try vaultFileURL
        let archivedURL = try availableArchivedVaultURL(reason: "corrupt")
        try fileManager.moveItem(at: fileURL, to: archivedURL)
        return archivedURL
    }

    func moveCurrentVaultAsideForNewVault() throws -> URL {
        guard vaultFileExists() else {
            throw VaultServiceError.missingVault
        }

        let fileURL = try vaultFileURL
        let archivedURL = try availableArchivedVaultURL(reason: "archived")
        try fileManager.moveItem(at: fileURL, to: archivedURL)
        return archivedURL
    }

    func archivedVaults() throws -> [ArchivedVault] {
        guard vaultDirectoryExists() else {
            return []
        }

        let directoryURL = try vaultDirectoryURL
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        return try fileURLs
            .filter { isArchivedVaultFileName($0.lastPathComponent) }
            .map { url in
                let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return ArchivedVault(
                    id: url.lastPathComponent,
                    fileName: url.lastPathComponent,
                    modifiedAt: resourceValues.contentModificationDate ?? .distantPast,
                    byteCount: Int64(resourceValues.fileSize ?? 0)
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func restoreArchivedVault(id: String) throws {
        let archivedVault = try archivedVaults().first { $0.id == id }
        guard let archivedVault else {
            throw VaultServiceError.archivedVaultNotFound
        }

        let directoryURL = try vaultDirectoryURL
        let archivedURL = directoryURL.appendingPathComponent(archivedVault.fileName)

        if vaultFileExists() {
            _ = try moveCurrentVaultAsideForNewVault()
        }

        try fileManager.moveItem(at: archivedURL, to: try vaultFileURL)
    }

    func deleteArchivedVault(id: String) throws {
        let archivedVault = try archivedVaults().first { $0.id == id }
        guard let archivedVault else {
            throw VaultServiceError.archivedVaultNotFound
        }

        let archivedURL = try vaultDirectoryURL
            .appendingPathComponent(archivedVault.fileName)
        try fileManager.removeItem(at: archivedURL)
    }

    func savePayload(_ payload: VaultPayload, using key: SymmetricKey) throws {
        guard let vaultFile = try loadVaultFile() else {
            throw VaultServiceError.missingVault
        }

        guard isValidPayload(payload) else {
            throw VaultServiceError.invalidVault
        }

        if vaultFile.formatVersion == 1 {
            _ = try archiveCurrentVaultForMigration()
        }

        let plaintext = try encodePayload(payload)
        guard plaintext.count <= VaultResourcePolicy.maximumPlaintextBytes else {
            throw VaultServiceError.invalidVault
        }
        let encryptedPayload = try cryptoService.encrypt(plaintext, using: key)
        let updatedVaultFile = VaultFile(
            formatVersion: Self.currentVaultFormatVersion,
            createdAt: vaultFile.createdAt,
            keyDerivation: vaultFile.keyDerivation,
            encryption: vaultFile.encryption,
            payloadEncoding: VaultPayloadEncoding.binaryPropertyList,
            encryptedPayload: VaultEncryptedPayload(payload: encryptedPayload)
        )

        try writeVaultFile(updatedVaultFile, to: try vaultFileURL)
    }

    #if DEBUG
    func validateVaultFileForDebug() throws {
        guard vaultFileExists() else {
            return
        }

        guard let vaultFile = try? loadVaultFile() else {
            return
        }

        guard vaultFile.formatVersion >= 1,
              !vaultFile.keyDerivation.algorithm.isEmpty,
              Data(base64Encoded: vaultFile.keyDerivation.salt) != nil,
              vaultFile.keyDerivation.iterations > 0,
              vaultFile.keyDerivation.keyLength == KeyDerivationService.defaultKeyByteCount,
              !vaultFile.encryption.algorithm.isEmpty
        else {
            assertionFailure("Vault file validation failed")
            return
        }

        let rawVaultData = try Data(contentsOf: try vaultFileURL)
        let forbiddenPlaintextMarkers = ["password", "derivedKey"]
        if let rawVaultString = String(data: rawVaultData, encoding: .utf8) {
            let lowercased = rawVaultString.lowercased()
            for marker in forbiddenPlaintextMarkers {
                precondition(!lowercased.contains(marker.lowercased()), "Vault file contains forbidden plaintext marker")
            }
        }
    }
    #endif

    private func makeNewVaultFile() throws -> VaultFile {
        VaultFile(
            formatVersion: Self.currentVaultFormatVersion,
            createdAt: Date(),
            keyDerivation: VaultKeyDerivationMetadata(
                metadata: try keyDerivationService.makeMetadata(iterations: newVaultIterationCount)
            ),
            encryption: .aes256GCM,
            payloadEncoding: VaultPayloadEncoding.binaryPropertyList,
            encryptedPayload: .emptyPlaceholder
        )
    }

    private func keyDerivationMetadata(from vaultMetadata: VaultKeyDerivationMetadata) -> KeyDerivationMetadata? {
        guard let algorithm = KeyDerivationMetadata.Algorithm(rawValue: vaultMetadata.algorithm),
              let salt = Data(base64Encoded: vaultMetadata.salt),
              (KeyDerivationService.defaultSaltByteCount...KeyDerivationService.maximumSaltByteCount).contains(salt.count),
              (1...KeyDerivationService.maximumIterationCount).contains(vaultMetadata.iterations),
              vaultMetadata.keyLength == KeyDerivationService.defaultKeyByteCount
        else {
            return nil
        }

        return KeyDerivationMetadata(
            algorithm: algorithm,
            salt: salt,
            iterations: vaultMetadata.iterations,
            keyLength: vaultMetadata.keyLength
        )
    }

    private func isSupportedVaultFile(_ vaultFile: VaultFile) -> Bool {
        guard vaultFile.encryption.algorithm == VaultEncryptionMetadata.aes256GCM.algorithm else {
            return false
        }

        switch vaultFile.formatVersion {
        case 1:
            return vaultFile.payloadEncoding == nil || vaultFile.payloadEncoding == VaultPayloadEncoding.json
        case Self.currentVaultFormatVersion:
            return vaultFile.payloadEncoding == VaultPayloadEncoding.binaryPropertyList
        default:
            return false
        }
    }

    private func writeVaultFile(_ vaultFile: VaultFile, to url: URL) throws {
        let data = try Self.encoder.encode(vaultFile)
        guard data.count <= VaultResourcePolicy.maximumVaultFileBytes else {
            throw VaultServiceError.invalidVault
        }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func encodePayload(_ payload: VaultPayload) throws -> Data {
        try Self.propertyListEncoder.encode(payload)
    }

    private func decodePayload(_ data: Data, for vaultFile: VaultFile) -> VaultPayload? {
        guard data.count <= VaultResourcePolicy.maximumPlaintextBytes else {
            return nil
        }

        if vaultFile.payloadEncoding == VaultPayloadEncoding.binaryPropertyList {
            return try? Self.propertyListDecoder.decode(VaultPayload.self, from: data)
        }

        return try? Self.decoder.decode(VaultPayload.self, from: data)
    }

    private func isValidPayload(_ payload: VaultPayload) -> Bool {
        guard VaultResourcePolicy.isStructurallyValid(payload) else {
            return false
        }

        var imagePixelsTotal = 0
        for note in payload.notes {
            guard let richContent = note.richContent else {
                continue
            }

            guard richContent.imageDisplayWidths.values.allSatisfy({ $0.isFinite && (0.10...1).contains($0) })
            else {
                return false
            }

            guard Set(richContent.imageAttachmentIDs).count == richContent.imageAttachmentIDs.count else {
                return false
            }

            let sourceIDs = richContent.imageSources.map(\.id)
            guard sourceIDs.count == richContent.imageAttachmentIDs.count,
                  Set(sourceIDs) == Set(richContent.imageAttachmentIDs)
            else {
                return false
            }

            var imagePixelsForNote = 0
            for source in richContent.imageSources {
                guard !source.filenameExtension.isEmpty,
                      !source.typeIdentifier.isEmpty,
                      let metadata = try? VaultResourcePolicy.imageMetadata(for: source.data)
                else {
                    return false
                }
                imagePixelsForNote += metadata.width * metadata.height
                imagePixelsTotal += metadata.width * metadata.height
                guard imagePixelsForNote <= VaultResourcePolicy.maximumImagePixelsPerNote,
                      imagePixelsTotal <= VaultResourcePolicy.maximumImagePixelsTotal
                else {
                    return false
                }
            }

            guard VaultResourcePolicy.isValidStoredRichText(
                richContent.rtfdData,
                expectedImageSources: richContent.imageSources
            ), let attributedString = VaultRichTextDocument.decode(richContent.rtfdData) else {
                return false
            }

            var isValid = true
            let attachmentCount = VaultRichTextDocument.attachmentLocations(in: attributedString).count
            let range = NSRange(location: 0, length: attributedString.length)
            attributedString.enumerateAttribute(.attachment, in: range) { value, _, stop in
                guard value != nil else {
                    return
                }
                guard value as? NSTextAttachment != nil else {
                    isValid = false
                    stop.pointee = true
                    return
                }
            }

            guard isValid,
                  attachmentCount == richContent.imageAttachmentIDs.count,
                  richContent.imageDisplayWidths.keys.allSatisfy({
                      richContent.imageAttachmentIDs.contains($0)
                  })
            else {
                return false
            }
        }
        return true
    }

    private func archiveCurrentVaultForMigration() throws -> URL {
        let sourceURL = try vaultFileURL
        let archivedURL = try availableArchivedVaultURL(reason: "migration")
        try fileManager.copyItem(at: sourceURL, to: archivedURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archivedURL.path)
        return archivedURL
    }

    private func availableArchivedVaultURL(reason: String) throws -> URL {
        let fileURL = try vaultFileURL
        let timestamp = Int(Date().timeIntervalSince1970)
        let baseName = "\(fileURL.lastPathComponent).\(reason).\(timestamp)"
        var candidate = fileURL.deletingLastPathComponent().appendingPathComponent(baseName)
        var suffix = 1

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = fileURL.deletingLastPathComponent()
                .appendingPathComponent("\(baseName).\(suffix)")
            suffix += 1
        }

        return candidate
    }

    private func isEmptyFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber
        else {
            return false
        }

        return fileSize.intValue == 0
    }

    private func isArchivedVaultFileName(_ fileName: String) -> Bool {
        Self.archiveReasons.contains { reason in
            fileName.hasPrefix("\(Self.vaultFileName).\(reason).")
        }
    }

    private func migrateLegacyVaultIfNeeded(
        from legacyDirectory: URL,
        to currentDirectory: URL
    ) throws {
        var isLegacyDirectory: ObjCBool = false
        let legacyDirectoryExists = fileManager.fileExists(
            atPath: legacyDirectory.path,
            isDirectory: &isLegacyDirectory
        ) && isLegacyDirectory.boolValue
        guard legacyDirectoryExists else {
            return
        }

        var isCurrentDirectory: ObjCBool = false
        let currentDirectoryExists = fileManager.fileExists(
            atPath: currentDirectory.path,
            isDirectory: &isCurrentDirectory
        ) && isCurrentDirectory.boolValue

        if !currentDirectoryExists {
            try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
            try migrateLegacyVaultFiles(from: currentDirectory, to: currentDirectory)
            return
        }

        try migrateLegacyVaultFiles(from: legacyDirectory, to: currentDirectory)
    }

    private func migrateLegacyVaultFiles(from sourceDirectory: URL, to destinationDirectory: URL) throws {
        let files = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for sourceURL in files {
            guard let destinationName = migratedVaultFileName(for: sourceURL.lastPathComponent) else {
                continue
            }
            let destinationURL = destinationDirectory.appendingPathComponent(destinationName)
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                continue
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        }
    }

    private func migratedVaultFileName(for legacyFileName: String) -> String? {
        if legacyFileName == Self.legacyVaultFileName {
            return Self.vaultFileName
        }

        for reason in Self.archiveReasons {
            let legacyPrefix = "\(Self.legacyVaultFileName).\(reason)."
            if legacyFileName.hasPrefix(legacyPrefix) {
                return "\(Self.vaultFileName).\(reason).\(legacyFileName.dropFirst(legacyPrefix.count))"
            }
        }
        return nil
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}

private extension VaultService {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static let propertyListEncoder: PropertyListEncoder = {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }()

    static let propertyListDecoder = PropertyListDecoder()
}
