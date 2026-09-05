import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import mac_pastebin

@MainActor
final class SecurityRegressionTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testCreationPasswordPolicyRejectsTrivialSecretsAndAcceptsLongUnicode() throws {
        XCTAssertThrowsError(try VaultPasswordPolicy.validate(""))
        XCTAssertThrowsError(try VaultPasswordPolicy.validate("x"))
        XCTAssertThrowsError(try VaultPasswordPolicy.validate("password1234"))
        XCTAssertThrowsError(try VaultPasswordPolicy.validate("aaaaaaaaaaaa"))
        XCTAssertNoThrow(try VaultPasswordPolicy.validate("🔐 café violet river 28"))

        let service = makeService()
        XCTAssertThrowsError(try service.createVault(password: "x"))
        XCTAssertNoThrow(try service.createVault(password: "🔐 café violet river 28"))
    }

    func testUnlockRemainsCompatibleWithExistingShortPasswordVault() throws {
        let service = makeService()
        try service.ensureVaultDirectoryExists()
        let password = "x"
        let metadata = try KeyDerivationService().makeMetadata(iterations: 1)
        let key = try KeyDerivationService().deriveKey(from: password, metadata: metadata)
        let payload = VaultPayload.singleEditorNote(body: "Legacy short password")
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        let encrypted = try CryptoService().encrypt(try plistEncoder.encode(payload), using: key)
        let vaultFile = VaultFile(
            formatVersion: 2,
            createdAt: Date(),
            keyDerivation: VaultKeyDerivationMetadata(metadata: metadata),
            encryption: .aes256GCM,
            payloadEncoding: VaultPayloadEncoding.binaryPropertyList,
            encryptedPayload: VaultEncryptedPayload(payload: encrypted)
        )
        try jsonEncoder.encode(vaultFile).write(to: service.vaultFileURL, options: .atomic)

        let reopened = try service.unlockVault(password: password)
        XCTAssertEqual(reopened.payload.selectedEditorText, "Legacy short password")
    }

    func testOversizedVaultIsRejectedFromMetadataAndRecoveryRemainsReachable() throws {
        let service = makeService()
        try service.ensureVaultDirectoryExists()
        let vaultFileURL = try service.vaultFileURL
        XCTAssertTrue(FileManager.default.createFile(atPath: vaultFileURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: vaultFileURL)
        try handle.truncate(atOffset: UInt64(VaultResourcePolicy.maximumVaultFileBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try service.loadVaultFile())

        let appState = AppState(vaultService: service)
        appState.createOrUnlockVault(password: "irrelevant password")
        XCTAssertTrue(appState.isLocked)
        XCTAssertTrue(appState.canReplaceCorruptedVault)
    }

    func testPayloadDecoderRejectsExcessiveNoteCount() throws {
        let now = Date()
        let notes = (0...VaultResourcePolicy.maximumNoteCount).map { index in
            VaultNote(
                id: "note-\(index)",
                title: "Note",
                body: "Body",
                createdAt: now,
                updatedAt: now,
                isTitleFinalized: true
            )
        }
        let payload = VaultPayload(formatVersion: 2, notes: notes, selectedNoteID: nil)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(payload)

        XCTAssertThrowsError(try PropertyListDecoder().decode(VaultPayload.self, from: data))
    }

    func testOversizedRTFDIsRejectedBeforeSaveParsing() throws {
        let service = makeService()
        let unlockResult = try service.createVault(password: "a unique test passphrase")
        let now = Date()
        let content = VaultRichContent(
            rtfdData: Data(count: VaultResourcePolicy.maximumRTFDBytesPerNote + 1)
        )
        let note = VaultNote(
            id: "oversized",
            title: "Oversized",
            body: "Body",
            createdAt: now,
            updatedAt: now,
            isTitleFinalized: true,
            richContent: content
        )
        let payload = VaultPayload(formatVersion: 2, notes: [note], selectedNoteID: note.id)

        XCTAssertFalse(VaultResourcePolicy.isStructurallyValid(payload))
        XCTAssertThrowsError(try service.savePayload(payload, using: unlockResult.key))
    }

    func testImagePreflightAcceptsSmallStillImageAndRejectsAnimation() throws {
        let image = try XCTUnwrap(bitmapRepresentation().cgImage)
        let png = try imageData(type: UTType.png, images: [image])
        let metadata = try VaultResourcePolicy.imageMetadata(for: png)
        XCTAssertEqual(metadata.width, 4)
        XCTAssertEqual(metadata.height, 4)
        XCTAssertEqual(metadata.frameCount, 1)

        let animatedGIF = try imageData(type: UTType.gif, images: [image, image])
        XCTAssertThrowsError(try VaultResourcePolicy.imageMetadata(for: animatedGIF))
    }

    func testImageOptimizationAcceptsSmallImagesWithoutUpscaling() throws {
        for dimension in [1, 4, 256, 319, 320] {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: dimension, pixelsHigh: dimension,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: dimension * 4, bitsPerPixel: 32
            ))
            let input = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let result = try ImageOptimizationService.optimizeImageData(input)
            XCTAssertEqual(result.width, dimension)
            XCTAssertEqual(result.height, dimension)
            XCTAssertLessThanOrEqual(result.data.count, ImageOptimizationService.maximumStoredBytes)
            XCTAssertNoThrow(try VaultResourcePolicy.imageMetadata(for: result.data))
        }
    }

    func testImageOptimizationDownsamplesAndCapsStoredData() throws {
        let representation = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2_400,
                pixelsHigh: 1_600,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 2_400 * 4,
                bitsPerPixel: 32
            )
        )
        let input = try XCTUnwrap(representation.representation(using: .png, properties: [:]))

        let optimized = try ImageOptimizationService.optimizeImageData(input)

        XCTAssertLessThanOrEqual(
            max(optimized.width, optimized.height),
            ImageOptimizationService.maximumPixelDimension
        )
        XCTAssertLessThanOrEqual(optimized.data.count, ImageOptimizationService.maximumStoredBytes)
        XCTAssertEqual(optimized.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(optimized.filenameExtension, "png")
        XCTAssertNoThrow(try VaultResourcePolicy.imageMetadata(for: optimized.data))
    }

    func testImageFileSizeIsRejectedBeforeReading() throws {
        let directory = makeTemporaryDirectory()
        let imageURL = directory.appendingPathComponent("oversized.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: imageURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: imageURL)
        try handle.truncate(atOffset: UInt64(ImageOptimizationService.maximumImportBytes + 1))
        try handle.close()

        XCTAssertThrowsError(try VaultResourcePolicy.validatedImageFileSize(at: imageURL))
    }

    func testEveryLockBoundaryInvalidatesPendingCredentials() {
        let appState = AppState(vaultService: makeService())
        let initialGeneration = appState.credentialResetGeneration

        appState.lock()

        XCTAssertEqual(appState.credentialResetGeneration, initialGeneration &+ 1)
    }

    func testSecureFieldConsumesEachCredentialResetOnlyOnce() {
        let field = MacPastebinSecurePasswordField(
            text: .constant("secret"),
            placeholder: "Password",
            accessibilityLabel: "Password",
            requestsInitialFocus: false,
            resetGeneration: 7,
            onSubmit: {}
        )
        let coordinator = field.makeCoordinator()

        XCTAssertFalse(coordinator.consumeResetGeneration(7))
        XCTAssertTrue(coordinator.consumeResetGeneration(8))
        XCTAssertFalse(coordinator.consumeResetGeneration(8))
    }

    func testSecureFieldDoesNotPublishDuringRepresentableUpdates() {
        var text = "secret"
        var publicationCount = 0
        let field = MacPastebinSecurePasswordField(
            text: Binding(
                get: { text },
                set: {
                    text = $0
                    publicationCount += 1
                }
            ),
            placeholder: "Password",
            accessibilityLabel: "Password",
            requestsInitialFocus: false,
            resetGeneration: 0,
            onSubmit: {}
        )
        let coordinator = field.makeCoordinator()
        let secureField = NSSecureTextField()
        secureField.stringValue = ""

        coordinator.performRepresentableUpdate {
            coordinator.controlTextDidChange(
                Notification(name: NSControl.textDidChangeNotification, object: secureField)
            )
        }

        XCTAssertEqual(text, "secret")
        XCTAssertEqual(publicationCount, 0)

        coordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: secureField)
        )
        XCTAssertEqual(text, "")
        XCTAssertEqual(publicationCount, 1)
    }

    func testEntireSecureFieldAcceptsAppReactivationClick() {
        let container = SecurePasswordContainer()

        XCTAssertTrue(container.acceptsFirstMouse(for: nil))
        XCTAssertTrue(container.textField.acceptsFirstMouse(for: nil))
    }

    func testSecureFieldDisablesPlaintextSuggestionSurfaces() {
        let field = ReactivatingSecureTextField()
        let editor = NSTextView()
        ReactivatingSecureTextField.disableTextAssistance(in: editor)

        XCTAssertTrue(field.cell is NSSecureTextFieldCell)
        XCTAssertFalse(field.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(field.allowsCharacterPickerTouchBarItem)
        XCTAssertFalse(field.allowsWritingTools)
        XCTAssertFalse(field.allowsWritingToolsAffordance)
        XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(editor.isGrammarCheckingEnabled)
        XCTAssertEqual(editor.enabledTextCheckingTypes, 0)
        XCTAssertEqual(editor.writingToolsBehavior, .none)
    }

    func testLockBoundaryEndsTheActiveTextInputSession() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let textView = MacPastebinTextView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = textView
        XCTAssertTrue(window.makeFirstResponder(textView))

        AppState.endActiveTextInputSessions(in: [window])

        XCTAssertFalse(window.firstResponder === textView)
    }

    func testSecureFieldFocusReplacesAStaleRichTextResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let rootView = NSView(frame: window.contentView?.bounds ?? .zero)
        let staleEditor = MacPastebinTextView(frame: rootView.bounds)
        let passwordContainer = SecurePasswordContainer(frame: rootView.bounds)
        rootView.addSubview(staleEditor)
        rootView.addSubview(passwordContainer)
        window.contentView = rootView
        XCTAssertTrue(window.makeFirstResponder(staleEditor))

        XCTAssertTrue(passwordContainer.focusPasswordField(in: window))
        XCTAssertTrue(
            window.firstResponder === passwordContainer.textField
                || window.firstResponder === passwordContainer.textField.currentEditor()
        )

        let fieldEditor = try XCTUnwrap(passwordContainer.textField.currentEditor() as? NSTextView)
        XCTAssertFalse(fieldEditor.isAutomaticTextCompletionEnabled)
        XCTAssertFalse(fieldEditor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(fieldEditor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(fieldEditor.isContinuousSpellCheckingEnabled)
        XCTAssertEqual(fieldEditor.enabledTextCheckingTypes, 0)
        XCTAssertEqual(fieldEditor.writingToolsBehavior, .none)
    }

    private func makeService() -> VaultService {
        VaultService(
            applicationSupportDirectory: makeTemporaryDirectory(),
            newVaultIterationCount: 1
        )
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPastebinSecurityTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func bitmapRepresentation() -> NSBitmapImageRep {
        NSBitmapImageRep(
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
    }

    private func imageData(type: UTType, images: [CGImage]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, type.identifier as CFString, images.count, nil)
        )
        for image in images {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
