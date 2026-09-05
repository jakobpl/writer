import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import mac_pastebin

@MainActor
final class VaultRichContentTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testLegacyVaultLocationMigratesWithoutLosingTheActiveVaultOrArchives() throws {
        let applicationSupportDirectory = makeTemporaryDirectory()
        let password = "legacy migration passphrase"
        let originalService = makeService(in: applicationSupportDirectory)
        _ = try originalService.createVault(password: password)

        let currentDirectory = try originalService.vaultDirectoryURL
        let currentFile = try originalService.vaultFileURL
        let legacyDirectoryName = String(
            decoding: [87, 114, 105, 116, 101, 114],
            as: UTF8.self
        )
        let legacyFileName = String(
            decoding: [118, 97, 117, 108, 116, 46, 119, 114, 105, 116, 101, 114],
            as: UTF8.self
        )
        let legacyDirectory = applicationSupportDirectory.appendingPathComponent(
            legacyDirectoryName,
            isDirectory: true
        )

        try FileManager.default.moveItem(at: currentDirectory, to: legacyDirectory)
        let legacyActiveFile = legacyDirectory.appendingPathComponent(legacyFileName)
        try FileManager.default.moveItem(
            at: legacyDirectory.appendingPathComponent(currentFile.lastPathComponent),
            to: legacyActiveFile
        )
        try FileManager.default.copyItem(
            at: legacyActiveFile,
            to: legacyDirectory.appendingPathComponent("\(legacyFileName).archived.1")
        )

        let migratedService = makeService(in: applicationSupportDirectory)
        XCTAssertTrue(migratedService.vaultFileExists())
        XCTAssertEqual(try migratedService.vaultFileURL.lastPathComponent, "vault.mac_pastebin")
        XCTAssertEqual(
            try migratedService.archivedVaults().map(\.fileName),
            ["vault.mac_pastebin.archived.1"]
        )
        XCTAssertNoThrow(try migratedService.unlockVault(password: password))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyDirectory.path))
    }

    func testVersionOneJSONPayloadDecodesWithoutRichContent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = VaultPayload(
            formatVersion: 1,
            notes: [
                VaultNote(
                    id: "legacy",
                    title: "Legacy",
                    body: "Plain text survives",
                    createdAt: now,
                    updatedAt: now,
                    isTitleFinalized: true
                )
            ],
            selectedNoteID: "legacy"
        )

        let data = try jsonEncoder.encode(payload)
        let decoded = try jsonDecoder.decode(VaultPayload.self, from: data)

        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertEqual(decoded.notes.first?.body, "Plain text survives")
        XCTAssertNil(decoded.notes.first?.richContent)
    }

    func testRichFormattingAndOriginalImageBytesSurviveEncryptedRoundTrip() throws {
        let directory = makeTemporaryDirectory()
        let service = makeService(in: directory)
        let unlockResult = try service.createVault(password: "correct horse battery staple")
        let fixture = try makeRichFixture()
        let preflight = try XCTUnwrap(
            NSAttributedString(rtfd: fixture.content.rtfdData, documentAttributes: nil)
        )
        var preflightIndex = 0
        preflight.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: preflight.length)
        ) { value, _, _ in
            guard value != nil else {
                return
            }
            guard value as? NSTextAttachment != nil else {
                if let value {
                    XCTFail("RTFD attachment decoded as \(String(describing: type(of: value)))")
                } else {
                    XCTFail("RTFD attachment decoded as nil")
                }
                return
            }
            preflightIndex += 1
        }
        XCTAssertEqual(preflightIndex, fixture.content.imageAttachmentIDs.count)
        let now = Date()
        let note = VaultNote(
            id: "rich-note",
            title: "Rich note",
            body: fixture.plainText,
            createdAt: now,
            updatedAt: now,
            isTitleFinalized: true,
            richContent: fixture.content
        )
        let payload = VaultPayload(formatVersion: 2, notes: [note], selectedNoteID: note.id)

        try service.savePayload(payload, using: unlockResult.key)
        let rawVault = try Data(contentsOf: service.vaultFileURL)
        XCTAssertNil(rawVault.range(of: Data(fixture.plainText.utf8)))
        for imageData in fixture.imageData.values {
            XCTAssertNil(rawVault.range(of: imageData))
        }

        let reopened = try service.unlockVault(password: "correct horse battery staple")
        XCTAssertEqual(reopened.payload, payload)
        let reopenedContent = try XCTUnwrap(reopened.payload.notes.first?.richContent)
        let attributedString = try XCTUnwrap(
            NSAttributedString(rtfd: reopenedContent.rtfdData, documentAttributes: nil)
        )

        let font = try XCTUnwrap(attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let traits = NSFontManager.shared.traits(of: font)
        XCTAssertTrue(traits.contains(.boldFontMask))
        XCTAssertTrue(traits.contains(.italicFontMask))
        XCTAssertEqual(font.pointSize, 24, accuracy: 0.01)
        XCTAssertNotNil(attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil))

        var attachmentCount = 0
        attributedString.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributedString.length)
        ) { value, _, _ in
            guard value != nil else {
                return
            }
            if value as? NSTextAttachment != nil {
                attachmentCount += 1
            }
        }

        XCTAssertEqual(attachmentCount, fixture.imageData.count)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: reopenedContent.imageSources.map { ($0.id, $0.data) }),
            fixture.imageData
        )
        XCTAssertEqual(reopenedContent.imageDisplayWidths, fixture.content.imageDisplayWidths)
    }

    func testSingleCopyImageStorageSurvivesEncryptedRoundTrip() throws {
        let directory = makeTemporaryDirectory()
        let service = makeService(in: directory)
        let unlockResult = try service.createVault(password: "correct horse battery staple")
        let fixture = try makeRichFixture()
        let legacyDocument = try XCTUnwrap(
            NSAttributedString(rtfd: fixture.content.rtfdData, documentAttributes: nil)
        )
        let storedDocument = try XCTUnwrap(VaultRichTextDocument.encode(legacyDocument))
        let content = VaultRichContent(
            rtfdData: storedDocument,
            imageAttachmentIDs: fixture.content.imageAttachmentIDs,
            imageDisplayWidths: fixture.content.imageDisplayWidths,
            imageSources: fixture.content.imageSources
        )
        let now = Date()
        let note = VaultNote(
            id: "single-copy",
            title: "Single copy",
            body: fixture.plainText,
            createdAt: now,
            updatedAt: now,
            isTitleFinalized: true,
            richContent: content
        )
        let payload = VaultPayload(formatVersion: 2, notes: [note], selectedNoteID: note.id)

        for imageData in fixture.imageData.values {
            XCTAssertNil(storedDocument.range(of: imageData))
        }
        try service.savePayload(payload, using: unlockResult.key)
        let reopened = try service.unlockVault(password: "correct horse battery staple")
        let reopenedContent = try XCTUnwrap(reopened.payload.notes.first?.richContent)
        let decoded = try XCTUnwrap(VaultRichTextDocument.decode(reopenedContent.rtfdData))

        XCTAssertEqual(reopened.payload, payload)
        XCTAssertEqual(
            VaultRichTextDocument.attachmentLocations(in: decoded).count,
            fixture.content.imageAttachmentIDs.count
        )
    }

    func testSavingVersionOneVaultCreatesEncryptedMigrationArchiveAndWritesVersionTwo() throws {
        let directory = makeTemporaryDirectory()
        let service = makeService(in: directory)
        try service.ensureVaultDirectoryExists()
        let password = "migration password"
        let metadata = try KeyDerivationService().makeMetadata(iterations: 1)
        let key = try KeyDerivationService().deriveKey(from: password, metadata: metadata)
        let payload = VaultPayload.singleEditorNote(body: "Legacy body")
        let legacyPayload = VaultPayload(
            formatVersion: 1,
            notes: payload.notes,
            selectedNoteID: payload.selectedNoteID
        )
        let encrypted = try CryptoService().encrypt(try jsonEncoder.encode(legacyPayload), using: key)
        let legacyFile = VaultFile(
            formatVersion: 1,
            createdAt: Date(),
            keyDerivation: VaultKeyDerivationMetadata(metadata: metadata),
            encryption: .aes256GCM,
            payloadEncoding: nil,
            encryptedPayload: VaultEncryptedPayload(payload: encrypted)
        )
        try jsonEncoder.encode(legacyFile).write(to: service.vaultFileURL, options: .atomic)

        let opened = try service.unlockVault(password: password)
        let upgraded = VaultPayload(
            formatVersion: 2,
            notes: opened.payload.notes,
            selectedNoteID: opened.payload.selectedNoteID
        )
        try service.savePayload(upgraded, using: opened.key)

        let currentFile = try XCTUnwrap(service.loadVaultFile())
        XCTAssertEqual(currentFile.formatVersion, 2)
        XCTAssertEqual(currentFile.payloadEncoding, VaultPayloadEncoding.binaryPropertyList)
        let migrationArchives = try service.archivedVaults().filter { $0.fileName.contains(".migration.") }
        XCTAssertEqual(migrationArchives.count, 1)
        XCTAssertGreaterThan(migrationArchives[0].byteCount, 0)
    }

    func testUnknownPayloadVersionIsRejectedInsteadOfBecomingPlainText() throws {
        let directory = makeTemporaryDirectory()
        let service = makeService(in: directory)
        try service.ensureVaultDirectoryExists()
        let password = "future password"
        let metadata = try KeyDerivationService().makeMetadata(iterations: 1)
        let key = try KeyDerivationService().deriveKey(from: password, metadata: metadata)
        let futurePayload = VaultPayload(formatVersion: 99, notes: [], selectedNoteID: nil)
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        let encrypted = try CryptoService().encrypt(try plistEncoder.encode(futurePayload), using: key)
        let futureFile = VaultFile(
            formatVersion: 2,
            createdAt: Date(),
            keyDerivation: VaultKeyDerivationMetadata(metadata: metadata),
            encryption: .aes256GCM,
            payloadEncoding: VaultPayloadEncoding.binaryPropertyList,
            encryptedPayload: VaultEncryptedPayload(payload: encrypted)
        )
        try jsonEncoder.encode(futureFile).write(to: service.vaultFileURL, options: .atomic)

        XCTAssertThrowsError(try service.unlockVault(password: password))
    }

    private func makeService(in applicationSupportDirectory: URL) -> VaultService {
        VaultService(
            applicationSupportDirectory: applicationSupportDirectory,
            newVaultIterationCount: 1
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPastebinTests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func makeRichFixture() throws -> (plainText: String, content: VaultRichContent, imageData: [String: Data]) {
        let plainText = "Formatted Unicode: café 🔒\n"
        let baseFont = NSFont.systemFont(ofSize: 24)
        let bold = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let boldItalic = NSFontManager.shared.convert(bold, toHaveTrait: .italicFontMask)
        let attributedString = NSMutableAttributedString(
            string: plainText,
            attributes: [
                .font: boldItalic,
                .foregroundColor: NSColor.systemPurple
            ]
        )

        let formats: [(String, NSBitmapImageRep.FileType)] = [
            ("png", .png),
            ("jpeg", .jpeg),
            ("gif", .gif),
            ("tiff", .tiff)
        ]
        var images: [String: Data] = [:]
        var attachmentIDs: [String] = []
        var imageSources: [VaultImageSource] = []
        var widths: [String: Double] = [:]
        for (name, type) in formats {
            let data = try XCTUnwrap(bitmapRepresentation().representation(using: type, properties: [:]))
            let identifier = "fixture-\(name)"
            appendImage(data: data, identifier: identifier, extension: name, to: attributedString)
            attachmentIDs.append(identifier)
            images[identifier] = data
            imageSources.append(
                VaultImageSource(
                    id: identifier,
                    data: data,
                    typeIdentifier: UTType(filenameExtension: name)?.identifier ?? UTType.image.identifier,
                    filenameExtension: name
                )
            )
            widths[identifier] = 0.25 + (Double(images.count) * 0.1)
        }

        if let heicData = makeHEICRepresentation() {
            let identifier = "fixture-heif"
            appendImage(data: heicData, identifier: identifier, extension: "heic", to: attributedString)
            attachmentIDs.append(identifier)
            images[identifier] = heicData
            imageSources.append(
                VaultImageSource(
                    id: identifier,
                    data: heicData,
                    typeIdentifier: UTType.heic.identifier,
                    filenameExtension: "heic"
                )
            )
            widths[identifier] = 0.75
        }

        let rtfd = try XCTUnwrap(
            attributedString.rtfd(
                from: NSRange(location: 0, length: attributedString.length),
                documentAttributes: [:]
            )
        )
        return (
            plainText,
            VaultRichContent(
                rtfdData: rtfd,
                imageAttachmentIDs: attachmentIDs,
                imageDisplayWidths: widths,
                imageSources: imageSources
            ),
            images
        )
    }

    private func appendImage(
        data: Data,
        identifier: String,
        extension pathExtension: String,
        to attributedString: NSMutableAttributedString
    ) {
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = "\(identifier).\(pathExtension)"
        attributedString.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        attributedString.append(NSAttributedString(string: "\n"))
    }

    private func bitmapRepresentation() -> NSBitmapImageRep {
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16,
            bitsPerPixel: 32
        )!
        for x in 0..<4 {
            for y in 0..<4 {
                representation.setColor((x + y).isMultiple(of: 2) ? .systemBlue : .systemPink, atX: x, y: y)
            }
        }
        return representation
    }

    private func makeHEICRepresentation() -> Data? {
        guard let cgImage = bitmapRepresentation().cgImage else {
            return nil
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
