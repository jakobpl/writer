import AppKit
import Combine
import XCTest
@testable import mac_pastebin

@MainActor
final class RichTextEditingTests: XCTestCase {
    func testLoadingDefersSelectionStatePublicationAndSkipsDuplicateValues() {
        let context = RichTextEditorContext()
        var publicationCount = 0
        let cancellable = context.objectWillChange.sink {
            publicationCount += 1
        }
        let editor = RichTextEditor(
            noteID: "note",
            plainText: "Loaded text",
            richContent: nil,
            context: context,
            onChange: { _, _ in },
            onError: { _ in },
            onFocus: {}
        )
        let coordinator = editor.makeCoordinator()
        let textView = MacPastebinTextView()
        coordinator.textView = textView

        coordinator.load(noteID: "note", plainText: "Loaded text", richContent: nil)
        XCTAssertEqual(publicationCount, 0)

        let selectionNotification = Notification(
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        coordinator.textViewDidChangeSelection(selectionNotification)
        XCTAssertGreaterThan(publicationCount, 0)

        let publicationCountAfterInitialUpdate = publicationCount
        coordinator.textViewDidChangeSelection(selectionNotification)
        XCTAssertEqual(publicationCount, publicationCountAfterInitialUpdate)
        withExtendedLifetime(cancellable) {}
    }

    func testLoadingLegacyRTFDCompactsItToLightweightRichText() throws {
        let legacyDocument = NSAttributedString(
            string: "Legacy formatting",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 22)]
        )
        let legacyRTFD = try XCTUnwrap(
            legacyDocument.rtfd(
                from: NSRange(location: 0, length: legacyDocument.length),
                documentAttributes: [:]
            )
        )
        var compactedContent: VaultRichContent?
        let editor = RichTextEditor(
            noteID: "note",
            plainText: "Legacy formatting",
            richContent: VaultRichContent(rtfdData: legacyRTFD),
            context: RichTextEditorContext(),
            onChange: { _, content in compactedContent = content },
            onError: { _ in },
            onFocus: {}
        )
        let coordinator = editor.makeCoordinator()
        let textView = MacPastebinTextView()
        coordinator.textView = textView

        coordinator.load(
            noteID: "note",
            plainText: "Legacy formatting",
            richContent: VaultRichContent(rtfdData: legacyRTFD)
        )

        let compacted = try XCTUnwrap(compactedContent)
        XCTAssertFalse(VaultRichTextDocument.isLegacyRTFD(compacted.rtfdData))
        XCTAssertNotNil(VaultRichTextDocument.decode(compacted.rtfdData))
    }

    func testFormattingPreviewCancelsWithoutSavingAndCommitCreatesOneChange() throws {
        let context = RichTextEditorContext()
        var savedChanges = 0
        let editor = RichTextEditor(
            noteID: "note",
            plainText: "Preview this text",
            richContent: nil,
            context: context,
            onChange: { _, _ in savedChanges += 1 },
            onError: { _ in },
            onFocus: {}
        )
        let coordinator = editor.makeCoordinator()
        let textView = MacPastebinTextView()
        coordinator.textView = textView
        coordinator.load(noteID: "note", plainText: "Preview this text", richContent: nil)
        textView.setSelectedRange(NSRange(location: 0, length: 7))

        coordinator.previewFontSize(42)
        XCTAssertEqual(fontSize(at: 0, in: textView), 42, accuracy: 0.01)
        XCTAssertEqual(savedChanges, 0)

        coordinator.cancelFormattingPreview()
        XCTAssertEqual(fontSize(at: 0, in: textView), 19, accuracy: 0.01)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 7))
        XCTAssertEqual(savedChanges, 0)

        coordinator.previewFontSize(32)
        coordinator.commitFormattingPreview()
        XCTAssertEqual(fontSize(at: 0, in: textView), 32, accuracy: 0.01)
        XCTAssertEqual(savedChanges, 1)
    }

    func testSwitchingNotesClearsUndoAndFormattingPreview() throws {
        let editor = RichTextEditor(
            noteID: "first", plainText: "First note", richContent: nil,
            context: RichTextEditorContext(), onChange: { _, _ in },
            onError: { _ in }, onFocus: {}
        )
        let coordinator = editor.makeCoordinator()
        let textView = MacPastebinTextView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = textView
        textView.allowsUndo = true
        coordinator.textView = textView
        coordinator.load(noteID: "first", plainText: "First note", richContent: nil)
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        coordinator.applyFontSize(32)
        let undoManager = try XCTUnwrap(textView.undoManager)
        XCTAssertTrue(undoManager.canUndo)
        coordinator.previewFontSize(48)

        coordinator.load(noteID: "second", plainText: "Second note", richContent: nil)
        XCTAssertFalse(undoManager.canUndo)
        coordinator.cancelFormattingPreview()
        XCTAssertEqual(textView.string, "Second note")
        XCTAssertEqual(fontSize(at: 0, in: textView), 19, accuracy: 0.01)

        textView.setSelectedRange(NSRange(location: 0, length: 6))
        coordinator.applyFontSize(28)
        XCTAssertTrue(undoManager.canUndo)
        coordinator.clearEditor()
        XCTAssertFalse(undoManager.canUndo)
        XCTAssertTrue(textView.string.isEmpty)
        withExtendedLifetime(window) {}
    }

    func testDocumentKeyboardShortcutsRouteToFormattingCommands() throws {
        let textView = MacPastebinTextView()
        var received: [EditorFormattingCommand] = []
        textView.onFormattingCommand = { received.append($0) }

        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("b", modifiers: .command, keyCode: 11)))
        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("1", modifiers: [.command, .option], keyCode: 18)))
        XCTAssertTrue(textView.performKeyEquivalent(with: try keyEvent("x", modifiers: [.command, .shift], keyCode: 7)))

        XCTAssertEqual(received.count, 3)
        if case .toggleBold = received[0] {} else { XCTFail("Expected bold command") }
        if case .heading(1) = received[1] {} else { XCTFail("Expected Heading 1 command") }
        if case .toggleStrikethrough = received[2] {} else { XCTFail("Expected strikethrough command") }
    }

    func testDocumentCommandsApplyCharacterParagraphAndListFormatting() throws {
        let context = RichTextEditorContext()
        let editor = RichTextEditor(
            noteID: "note",
            plainText: "First paragraph\nSecond paragraph",
            richContent: nil,
            context: context,
            onChange: { _, _ in },
            onError: { _ in },
            onFocus: {}
        )
        let coordinator = editor.makeCoordinator()
        let textView = MacPastebinTextView()
        coordinator.textView = textView
        coordinator.load(noteID: "note", plainText: "First paragraph\nSecond paragraph", richContent: nil)
        textView.setSelectedRange(NSRange(location: 0, length: 5))

        coordinator.performEditorCommand(.toggleBold)
        let boldFont = try XCTUnwrap(textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        coordinator.performEditorCommand(.toggleUnderline)
        XCTAssertEqual(textView.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)

        coordinator.performEditorCommand(.heading(1))
        XCTAssertEqual(fontSize(at: 0, in: textView), 32, accuracy: 0.01)

        coordinator.performEditorCommand(.alignCenter)
        let centered = try XCTUnwrap(textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(centered.alignment, .center)
        XCTAssertEqual(context.textAlignment, .center)

        coordinator.performEditorCommand(.alignRight)
        let rightAligned = try XCTUnwrap(textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(rightAligned.alignment, .right)
        XCTAssertEqual(context.textAlignment, .right)

        coordinator.performEditorCommand(.bulletedList)
        let listed = try XCTUnwrap(textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(listed.textLists.count, 1)
        XCTAssertEqual(listed.textLists.first?.markerFormat, .disc)
    }

    func testMovingImageSnapsItToAParagraphBoundaryAndAlignsItLeft() throws {
        let context = RichTextEditorContext()
        let editor = RichTextEditor(
            noteID: "note",
            plainText: "",
            richContent: nil,
            context: context,
            onChange: { _, _ in },
            onError: { _ in },
            onFocus: {}
        )
        let coordinator = editor.makeCoordinator()
        let textView = MacPastebinTextView()
        coordinator.textView = textView

        let document = NSMutableAttributedString(string: "First paragraph\nSecond paragraph\n")
        let imageLocation = document.length
        document.append(NSAttributedString(attachment: NSTextAttachment()))
        document.append(NSAttributedString(string: "\n"))
        textView.textStorage?.setAttributedString(document)
        textView.setSelectedRange(NSRange(location: imageLocation, length: 1))

        coordinator.moveImage(from: imageLocation, to: 0)

        XCTAssertTrue(textView.textStorage?.attribute(.attachment, at: 0, effectiveRange: nil) is NSTextAttachment)
        let imageStyle = try XCTUnwrap(
            textView.textStorage?.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(imageStyle.alignment, .left)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 1))
        XCTAssertLessThanOrEqual(
            NSMaxRange(textView.selectedRange()),
            textView.textStorage?.length ?? 0
        )
    }

    func testImageDisplaySizePreservesAspectRatioAndCapsBothDimensions() {
        let wide = RichTextImageLayout.displaySize(
            for: CGSize(width: 2_400, height: 1_200),
            containerWidth: 1_200,
            widthFraction: 1
        )
        XCTAssertLessThanOrEqual(wide.width, RichTextImageLayout.maximumWidth)
        XCTAssertLessThanOrEqual(wide.height, RichTextImageLayout.maximumHeight)
        XCTAssertEqual(wide.width / wide.height, 2, accuracy: 0.001)

        let tall = RichTextImageLayout.displaySize(
            for: CGSize(width: 800, height: 2_400),
            containerWidth: 1_200,
            widthFraction: 1
        )
        XCTAssertLessThanOrEqual(tall.width, RichTextImageLayout.maximumWidth)
        XCTAssertLessThanOrEqual(tall.height, RichTextImageLayout.maximumHeight)
        XCTAssertEqual(tall.height / tall.width, 3, accuracy: 0.001)
    }

    func testImageDisplaySizeUsesTheDefaultFractionForInvalidPersistedValues() {
        let size = RichTextImageLayout.displaySize(
            for: CGSize(width: 400, height: 200),
            containerWidth: 600,
            widthFraction: .nan
        )

        XCTAssertEqual(size.width, 180, accuracy: 0.001)
        XCTAssertEqual(size.height, 90, accuracy: 0.001)
    }

    func testImageDisplaySizeNeverUpscalesSmallImages() {
        let size = RichTextImageLayout.displaySize(
            for: CGSize(width: 96, height: 64),
            containerWidth: 1_200,
            widthFraction: 1
        )

        XCTAssertEqual(size.width, 96, accuracy: 0.001)
        XCTAssertEqual(size.height, 64, accuracy: 0.001)
    }

    func testLargePortraitImageUsesAnAppropriateEditorSize() {
        let size = RichTextImageLayout.displaySize(
            for: CGSize(width: 4_284, height: 5_712),
            containerWidth: 1_200,
            widthFraction: RichTextImageLayout.defaultWidthFraction
        )

        XCTAssertEqual(size.width, 165, accuracy: 0.001)
        XCTAssertEqual(size.height, 220, accuracy: 0.001)
    }

    func testApplyingImageDisplaySizeUpdatesTheTextKitAttachmentCell() throws {
        let attachment = NSTextAttachment()
        let image = NSImage(size: NSSize(width: 1_200, height: 800))
        let displaySize = NSSize(width: 300, height: 200)

        XCTAssertTrue(
            RichTextImageLayout.applyDisplaySize(
                displaySize,
                to: attachment,
                image: image
            )
        )

        XCTAssertEqual(attachment.bounds.size, displaySize)
        XCTAssertEqual(try XCTUnwrap(attachment.attachmentCell).cellSize(), displaySize)
        XCTAssertTrue(attachment.attachmentCell is RoundedImageAttachmentCell)

        let textView = MacPastebinTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        textView.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let textContainer = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: 1))
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualCharacterRange: nil
        )
        let renderedBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

        XCTAssertEqual(renderedBounds.width, displaySize.width, accuracy: 0.001)
        XCTAssertEqual(renderedBounds.height, displaySize.height, accuracy: 0.001)
    }

    func testStoredRichTextUsesMarkersInsteadOfDuplicatingAttachmentBytes() throws {
        let imageBytes = Data(repeating: 0xA5, count: 64 * 1_024)
        let wrapper = FileWrapper(regularFileWithContents: imageBytes)
        wrapper.preferredFilename = "image.png"
        let document = NSMutableAttributedString(string: "Before ")
        document.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        document.append(NSAttributedString(string: " after"))

        let encoded = try XCTUnwrap(VaultRichTextDocument.encode(document))
        let decoded = try XCTUnwrap(VaultRichTextDocument.decode(encoded))

        XCTAssertLessThan(encoded.count, imageBytes.count)
        XCTAssertNil(encoded.range(of: imageBytes))
        XCTAssertEqual(VaultRichTextDocument.attachmentLocations(in: decoded).count, 1)
        XCTAssertNil(decoded.attribute(.attachment, at: 7, effectiveRange: nil))
    }

    private func fontSize(at location: Int, in textView: NSTextView) -> CGFloat {
        (textView.textStorage?.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
    }

    private func keyEvent(
        _ character: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: character,
                charactersIgnoringModifiers: character,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}
