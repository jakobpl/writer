import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol RichTextEditorCommandHandling: AnyObject {
    func applyFontFamily(_ family: String)
    func previewFontFamily(_ family: String)
    func applyFontSize(_ size: Double)
    func previewFontSize(_ size: Double)
    func toggleBold()
    func toggleItalic()
    func applyTextColor(_ color: NSColor)
    func previewTextColor(_ color: NSColor)
    func cancelFormattingPreview()
    func commitFormattingPreview()
    func performEditorCommand(_ command: EditorFormattingCommand)
    func insertImage()
    func focusEditor()
    func clearEditor()
}

enum EditorFormattingCommand {
    case toggleBold
    case toggleItalic
    case toggleUnderline
    case toggleStrikethrough
    case heading(Int)
    case copyFormatting
    case pasteFormatting
    case clearFormatting
    case increaseFontSize
    case decreaseFontSize
    case subscriptText
    case superscriptText
    case alignLeft
    case alignCenter
    case alignRight
    case justify
    case bulletedList
    case numberedList
    case indent
    case outdent
}

enum RichTextImageLayout {
    static let defaultWidthFraction = 0.30
    static let maximumWidth: CGFloat = 300
    static let maximumHeight: CGFloat = 220

    static func displaySize(
        for imageSize: CGSize,
        containerWidth: CGFloat,
        widthFraction: Double
    ) -> CGSize {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              imageSize.width > 0,
              imageSize.height > 0
        else {
            return CGSize(width: 1, height: 1)
        }

        let safeFraction = widthFraction.isFinite
            ? min(max(widthFraction, 0.10), 1)
            : defaultWidthFraction
        let width = min(
            max(containerWidth * safeFraction, 1),
            maximumWidth,
            imageSize.width
        )
        let proportionalHeight = width * imageSize.height / imageSize.width
        let scale = min(1, maximumHeight / proportionalHeight)
        return CGSize(width: width * scale, height: proportionalHeight * scale)
    }

    @discardableResult
    static func applyDisplaySize(
        _ displaySize: CGSize,
        to attachment: NSTextAttachment,
        image: NSImage?
    ) -> Bool {
        let bounds = CGRect(origin: .zero, size: displaySize)
        let cellAlreadyMatches = attachment.attachmentCell?.cellSize() == displaySize
        guard attachment.bounds != bounds || !cellAlreadyMatches else { return false }

        attachment.bounds = bounds

        // NSTextView's TextKit 1 layout takes an attachment's visible size from
        // its cell, not from NSTextAttachment.bounds. Keep both in sync so the
        // original file wrapper is preserved while AppKit draws the scaled image.
        if let image {
            image.size = displaySize
            let cell = RoundedImageAttachmentCell(imageCell: image)
            attachment.attachmentCell = cell
            cell.attachment = attachment
        }

        return true
    }
}

private extension NSAttributedString.Key {
    static let pendingImageImportID = NSAttributedString.Key("macPastebinPendingImageImportID")
}

final class RoundedImageAttachmentCell: NSTextAttachmentCell {
    static let cornerRadius: CGFloat = 12

    override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let image else {
            super.draw(withFrame: cellFrame, in: controlView)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        let radius = min(Self.cornerRadius, min(cellFrame.width, cellFrame.height) / 2)
        NSBezierPath(roundedRect: cellFrame, xRadius: radius, yRadius: radius).addClip()
        image.draw(
            in: cellFrame,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
final class RichTextEditorContext: ObservableObject {
    @Published private(set) var fontFamily: String? = NSFont.systemFont(ofSize: 19).familyName
    @Published private(set) var fontSize: Double? = 19
    @Published private(set) var isBold: Bool?
    @Published private(set) var isItalic: Bool?
    @Published private(set) var textColor = NSColor.macPastebinPaperInk
    @Published private(set) var textAlignment: NSTextAlignment? = .left

    weak var commandHandler: RichTextEditorCommandHandling?

    func applyFontFamily(_ family: String) {
        commandHandler?.applyFontFamily(family)
    }

    func previewFontFamily(_ family: String) {
        commandHandler?.previewFontFamily(family)
    }

    func applyFontSize(_ size: Double) {
        commandHandler?.applyFontSize(min(max(size, 6), 144))
    }

    func previewFontSize(_ size: Double) {
        commandHandler?.previewFontSize(min(max(size, 6), 144))
    }

    func toggleBold() {
        commandHandler?.toggleBold()
    }

    func toggleItalic() {
        commandHandler?.toggleItalic()
    }

    func applyTextColor(_ color: NSColor) {
        commandHandler?.applyTextColor(color)
    }

    func previewTextColor(_ color: NSColor) {
        commandHandler?.previewTextColor(color)
    }

    func cancelFormattingPreview() {
        commandHandler?.cancelFormattingPreview()
    }

    func commitFormattingPreview() {
        commandHandler?.commitFormattingPreview()
    }

    func insertImage() {
        commandHandler?.insertImage()
    }

    func alignLeft() {
        commandHandler?.performEditorCommand(.alignLeft)
    }

    func alignCenter() {
        commandHandler?.performEditorCommand(.alignCenter)
    }

    func alignRight() {
        commandHandler?.performEditorCommand(.alignRight)
    }

    func focusEditor() {
        commandHandler?.focusEditor()
    }

    func clear() {
        commandHandler?.clearEditor()
        commandHandler = nil
    }

    fileprivate func update(
        fontFamily: String?,
        fontSize: Double?,
        isBold: Bool?,
        isItalic: Bool?,
        textColor: NSColor,
        textAlignment: NSTextAlignment?
    ) {
        if self.fontFamily != fontFamily {
            self.fontFamily = fontFamily
        }
        if self.fontSize != fontSize {
            self.fontSize = fontSize
        }
        if self.isBold != isBold {
            self.isBold = isBold
        }
        if self.isItalic != isItalic {
            self.isItalic = isItalic
        }
        if !self.textColor.isEqual(textColor) {
            self.textColor = textColor
        }
        if self.textAlignment != textAlignment {
            self.textAlignment = textAlignment
        }
    }
}

struct FontFamilyComboBox: NSViewRepresentable {
    @Binding var family: String
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.usesDataSource = false
        comboBox.completes = true
        comboBox.isEditable = true
        comboBox.font = .systemFont(ofSize: 13)
        comboBox.addItems(withObjectValues: NSFontManager.shared.availableFontFamilies.sorted())
        comboBox.stringValue = family
        comboBox.delegate = context.coordinator
        comboBox.setAccessibilityLabel("Font family")
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if comboBox.currentEditor() == nil, comboBox.stringValue != family {
            comboBox.stringValue = family
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: FontFamilyComboBox

        init(parent: FontFamilyComboBox) {
            self.parent = parent
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            commit(notification)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            commit(obj)
        }

        private func commit(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox else {
                return
            }

            let value = comboBox.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NSFontManager.shared.availableFontFamilies.contains(value) else {
                comboBox.stringValue = parent.family
                return
            }

            parent.family = value
            parent.onCommit(value)
        }
    }
}

struct RichTextEditor: NSViewRepresentable {
    let noteID: String?
    let plainText: String
    let richContent: VaultRichContent?
    let context: RichTextEditorContext
    let onChange: (String, VaultRichContent) -> Void
    let onError: (String) -> Void
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = MacPastebinTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 22, height: 22)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.drawsBackground = false
        textView.textColor = .macPastebinPaperInk
        textView.insertionPointColor = .macPastebinPaperInk
        textView.font = .systemFont(ofSize: 19)
        textView.typingAttributes = Coordinator.defaultAttributes
        textView.setAccessibilityLabel("Note editor")

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.configureImageInteractions()
        self.context.commandHandler = context.coordinator
        context.coordinator.load(noteID: noteID, plainText: plainText, richContent: richContent)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        self.context.commandHandler = context.coordinator

        if context.coordinator.loadedNoteID != noteID {
            context.coordinator.load(noteID: noteID, plainText: plainText, richContent: richContent)
        }

        context.coordinator.scheduleAttachmentBoundsUpdate()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.clearEditor()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, RichTextEditorCommandHandling {
        static let defaultAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 19),
            .foregroundColor: NSColor.macPastebinPaperInk
        ]

        var parent: RichTextEditor
        weak var textView: MacPastebinTextView?
        var loadedNoteID: String?
        private var imageDisplayWidths: [String: Double] = [:]
        private var attachmentIDsByObject: [ObjectIdentifier: String] = [:]
        private var imageSourcesByID: [String: VaultImageSource] = [:]
        private var imageImportTasks: [String: Task<Void, Never>] = [:]
        private var isLoading = false
        private var isAttachmentBoundsUpdateScheduled = false
        private var formattingPreview: FormattingPreview?
        private var copiedFormatting: [NSAttributedString.Key: Any]?

        private struct FormattingPreview {
            let attributedString: NSAttributedString
            let typingAttributes: [NSAttributedString.Key: Any]
            let selection: NSRange
            let imageDisplayWidths: [String: Double]
            let actionName: String
        }

        init(parent: RichTextEditor) {
            self.parent = parent
        }

        func configureImageInteractions() {
            guard let textView else { return }
            textView.onSelectImage = { [weak self] location in
                self?.selectImage(at: location)
            }
            textView.onDeleteImage = { [weak self] location in
                self?.deleteImage(at: location)
            }
            textView.onMoveImage = { [weak self] source, destination in
                self?.moveImage(from: source, to: destination)
            }
            textView.onViewportWidthChange = { [weak self] in
                self?.scheduleAttachmentBoundsUpdate()
            }
            textView.onFormattingCommand = { [weak self] command in
                self?.performEditorCommand(command)
            }
        }

        func load(noteID: String?, plainText: String, richContent: VaultRichContent?) {
            guard let textView else {
                return
            }

            if loadedNoteID != noteID {
                imageImportTasks.values.forEach { $0.cancel() }
                imageImportTasks.removeAll(keepingCapacity: false)
            }
            // Undo and transient previews belong to the document being replaced.
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
            formattingPreview = nil
            textView.selectedImageCharacterIndex = nil
            isLoading = true
            loadedNoteID = noteID
            let shouldCompactLegacyRichText = richContent.map {
                VaultRichTextDocument.isLegacyRTFD($0.rtfdData)
            } ?? false
            imageDisplayWidths = richContent?.imageDisplayWidths ?? [:]
            attachmentIDsByObject.removeAll(keepingCapacity: true)
            imageSourcesByID = Dictionary(
                uniqueKeysWithValues: (richContent?.imageSources ?? []).map { ($0.id, $0) }
            )

            let attributedString: NSAttributedString
            if let data = richContent?.rtfdData,
               let decoded = VaultRichTextDocument.decode(data) {
                attributedString = decoded
            } else {
                attributedString = NSAttributedString(string: plainText, attributes: Self.defaultAttributes)
            }

            textView.textStorage?.setAttributedString(attributedString)
            rebuildAttachmentsFromOriginalSources(richContent?.imageAttachmentIDs ?? [])
            textView.typingAttributes = Self.defaultAttributes
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            assignAttachmentIdentifiers(richContent?.imageAttachmentIDs ?? [])
            updateAttachmentBounds()
            isLoading = false
            if shouldCompactLegacyRichText {
                emitChange()
            }
            scheduleSelectionStateUpdate()
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading else {
                return
            }

            emitChange()
            updateSelectionState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else {
                return
            }
            updateSelectionState()
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
            updateSelectionState()
        }

        func applyFontFamily(_ family: String) {
            transformFonts { font in
                NSFontManager.shared.convert(font, toFamily: family)
            }
        }

        func previewFontFamily(_ family: String) {
            previewFormatting(actionName: "Change Font") { [weak self] in
                self?.transformFontsWithoutCommit { font in
                    NSFontManager.shared.convert(font, toFamily: family)
                }
            }
        }

        func applyFontSize(_ size: Double) {
            let clampedSize = CGFloat(min(max(size, 6), 144))
            transformFonts { font in
                NSFontManager.shared.convert(font, toSize: clampedSize)
            }
        }

        func previewFontSize(_ size: Double) {
            let clampedSize = CGFloat(min(max(size, 6), 144))
            previewFormatting(actionName: "Change Font Size") { [weak self] in
                self?.transformFontsWithoutCommit { font in
                    NSFontManager.shared.convert(font, toSize: clampedSize)
                }
            }
        }

        func toggleBold() {
            let shouldEnable = parent.context.isBold != true
            transformFonts { font in
                NSFontManager.shared.convert(
                    font,
                    toHaveTrait: shouldEnable ? .boldFontMask : .unboldFontMask
                )
            }
        }

        func toggleItalic() {
            let shouldEnable = parent.context.isItalic != true
            transformFonts { font in
                NSFontManager.shared.convert(
                    font,
                    toHaveTrait: shouldEnable ? .italicFontMask : .unitalicFontMask
                )
            }
        }

        func applyTextColor(_ color: NSColor) {
            applyAttribute(.foregroundColor, value: color)
        }

        func previewTextColor(_ color: NSColor) {
            previewFormatting(actionName: "Change Text Color") { [weak self] in
                self?.applyAttributeWithoutCommit(.foregroundColor, value: color)
            }
        }

        func cancelFormattingPreview() {
            guard let preview = formattingPreview else { return }
            restorePreview(preview)
            formattingPreview = nil
            updateSelectionState()
        }

        func commitFormattingPreview() {
            guard let preview = formattingPreview, let textView else { return }
            formattingPreview = nil
            registerUndo(
                attributedString: preview.attributedString,
                imageDisplayWidths: preview.imageDisplayWidths,
                selection: preview.selection,
                actionName: preview.actionName
            )
            textView.undoManager?.setActionName(preview.actionName)
            emitChange()
            updateSelectionState()
        }

        func performEditorCommand(_ command: EditorFormattingCommand) {
            switch command {
            case .toggleBold:
                toggleBold()
            case .toggleItalic:
                toggleItalic()
            case .toggleUnderline:
                toggleIntegerAttribute(.underlineStyle, actionName: "Underline")
            case .toggleStrikethrough:
                toggleIntegerAttribute(.strikethroughStyle, actionName: "Strikethrough")
            case .heading(let level):
                applyHeading(level)
            case .copyFormatting:
                copySelectedFormatting()
            case .pasteFormatting:
                pasteCopiedFormatting()
            case .clearFormatting:
                clearSelectedFormatting()
            case .increaseFontSize:
                adjustFontSize(by: 1)
            case .decreaseFontSize:
                adjustFontSize(by: -1)
            case .subscriptText:
                toggleScript(-1)
            case .superscriptText:
                toggleScript(1)
            case .alignLeft:
                applyAlignment(.left)
            case .alignCenter:
                applyAlignment(.center)
            case .alignRight:
                applyAlignment(.right)
            case .justify:
                applyAlignment(.justified)
            case .bulletedList:
                applyList(markerFormat: .disc)
            case .numberedList:
                applyList(markerFormat: .decimal)
            case .indent:
                adjustIndent(by: 24)
            case .outdent:
                adjustIndent(by: -24)
            }
        }

        private func toggleIntegerAttribute(_ key: NSAttributedString.Key, actionName: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = effectiveFormattingRange(in: textView, storage: storage)
            let current = range.length > 0
                ? (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0)
                : (textView.typingAttributes[key] as? Int ?? 0)
            performMutation(actionName: actionName) {
                self.applyAttributeWithoutCommit(key, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0)
            }
        }

        private func adjustFontSize(by delta: CGFloat) {
            transformFonts { font in
                NSFontManager.shared.convert(font, toSize: min(max(font.pointSize + delta, 6), 144))
            }
        }

        private func toggleScript(_ value: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let key = NSAttributedString.Key.superscript
            let range = effectiveFormattingRange(in: textView, storage: storage)
            let current = range.length > 0
                ? (storage.attribute(key, at: range.location, effectiveRange: nil) as? Int ?? 0)
                : (textView.typingAttributes[key] as? Int ?? 0)
            performMutation(actionName: value > 0 ? "Superscript" : "Subscript") {
                self.applyAttributeWithoutCommit(key, value: current == value ? 0 : value)
            }
        }

        private func applyHeading(_ level: Int) {
            let size: CGFloat
            let shouldBold: Bool
            switch level {
            case 1: (size, shouldBold) = (32, true)
            case 2: (size, shouldBold) = (26, true)
            case 3: (size, shouldBold) = (22, true)
            default: (size, shouldBold) = (19, false)
            }

            performMutation(actionName: level == 0 ? "Normal Text" : "Heading \(level)") {
                guard let textView, let storage = textView.textStorage else { return }
                let range = self.paragraphRange(in: textView, storage: storage)
                storage.enumerateAttribute(.font, in: range) { value, attributeRange, _ in
                    let oldFont = value as? NSFont ?? .systemFont(ofSize: 19)
                    let family = oldFont.familyName ?? NSFont.systemFont(ofSize: size).familyName ?? "Helvetica"
                    let font = NSFontManager.shared.convert(
                        NSFontManager.shared.convert(oldFont, toFamily: family),
                        toSize: size
                    )
                    let result = NSFontManager.shared.convert(
                        font,
                        toHaveTrait: shouldBold ? .boldFontMask : .unboldFontMask
                    )
                    storage.addAttribute(.font, value: result, range: attributeRange)
                }
            }
        }

        private func copySelectedFormatting() {
            guard let textView, let storage = textView.textStorage, storage.length > 0 else { return }
            cancelFormattingPreview()
            let location = min(textView.selectedRange().location, storage.length - 1)
            copiedFormatting = storage.attributes(at: location, effectiveRange: nil).filter {
                $0.key != .attachment
            }
        }

        private func pasteCopiedFormatting() {
            guard let copiedFormatting else { return }
            performMutation(actionName: "Paste Formatting") {
                guard let textView, let storage = textView.textStorage else { return }
                let range = self.effectiveFormattingRange(in: textView, storage: storage)
                if range.length == 0 {
                    textView.typingAttributes.merge(copiedFormatting) { _, new in new }
                } else {
                    for (key, value) in copiedFormatting {
                        storage.addAttribute(key, value: value, range: range)
                    }
                }
            }
        }

        private func clearSelectedFormatting() {
            performMutation(actionName: "Clear Formatting") {
                guard let textView, let storage = textView.textStorage else { return }
                let range = self.effectiveFormattingRange(in: textView, storage: storage)
                if range.length == 0 {
                    textView.typingAttributes = Self.defaultAttributes
                    return
                }
                storage.addAttributes(Self.defaultAttributes, range: range)
                for key in [NSAttributedString.Key.underlineStyle, .strikethroughStyle, .superscript, .baselineOffset, .backgroundColor] {
                    storage.removeAttribute(key, range: range)
                }
                let paragraphRange = self.paragraphRange(in: textView, storage: storage)
                storage.addAttribute(.paragraphStyle, value: NSParagraphStyle.default, range: paragraphRange)
            }
        }

        private func applyAlignment(_ alignment: NSTextAlignment) {
            mutateParagraphs(actionName: "Align Text") { style in
                style.alignment = alignment
            }
        }

        private func applyList(markerFormat: NSTextList.MarkerFormat) {
            mutateParagraphs(actionName: "Format List") { style in
                let alreadyApplied = style.textLists.first?.markerFormat == markerFormat
                style.textLists = alreadyApplied ? [] : [NSTextList(markerFormat: markerFormat, options: 0)]
                style.headIndent = alreadyApplied ? 0 : 24
                style.firstLineHeadIndent = 0
            }
        }

        private func adjustIndent(by delta: CGFloat) {
            mutateParagraphs(actionName: delta > 0 ? "Indent" : "Outdent") { style in
                style.headIndent = max(0, style.headIndent + delta)
                if style.textLists.isEmpty {
                    style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
                }
            }
        }

        private func mutateParagraphs(actionName: String, mutation: @escaping (NSMutableParagraphStyle) -> Void) {
            performMutation(actionName: actionName) {
                guard let textView, let storage = textView.textStorage else { return }
                let range = self.paragraphRange(in: textView, storage: storage)
                storage.enumerateAttribute(.paragraphStyle, in: range) { value, attributeRange, _ in
                    let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                        ?? NSMutableParagraphStyle()
                    mutation(style)
                    storage.addAttribute(.paragraphStyle, value: style, range: attributeRange)
                }
            }
        }

        private func effectiveFormattingRange(in textView: NSTextView, storage: NSTextStorage) -> NSRange {
            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            guard selection.length == 0, storage.length > 0 else { return selection }
            return NSRange(location: min(selection.location, storage.length - 1), length: 0)
        }

        private func paragraphRange(in textView: NSTextView, storage: NSTextStorage) -> NSRange {
            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            let safeLocation = min(selection.location, storage.length)
            return (storage.string as NSString).paragraphRange(
                for: NSRange(location: safeLocation, length: min(selection.length, storage.length - safeLocation))
            )
        }

        func insertImage() {
            guard textView != nil else {
                return
            }

            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "Insert"
            panel.message = "Choose a still image to insert into this encrypted note."

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            guard currentAttachmentIDs().count + imageImportTasks.count
                    < VaultResourcePolicy.maximumAttachmentsPerNote
            else {
                parent.onError("This note already has the maximum number of images.")
                return
            }

            let importID = UUID().uuidString
            let noteID = loadedNoteID
            insertImagePlaceholder(id: importID)

            imageImportTasks[importID] = Task { [weak self] in
                do {
                    let optimized = try await Task.detached(priority: .userInitiated) {
                        try ImageOptimizationService.optimizeImage(at: url)
                    }.value
                    guard !Task.isCancelled else { return }
                    self?.finishImageImport(optimized, id: importID, noteID: noteID)
                } catch ImageOptimizationService.OptimizationError.resourceLimitExceeded {
                    self?.failImageImport(
                        id: importID,
                        message: "That image is too large or complex to optimize safely."
                    )
                } catch {
                    self?.failImageImport(
                        id: importID,
                        message: "The image could not be optimized or is not a supported still image."
                    )
                }
            }
        }

        private func insertImagePlaceholder(id: String) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            let placeholder = NSAttributedString(
                string: "⏳ Optimizing image for encryption…",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .pendingImageImportID: id
                ]
            )

            isLoading = true
            storage.replaceCharacters(in: selection, with: placeholder)
            textView.setSelectedRange(
                NSRange(location: selection.location + placeholder.length, length: 0)
            )
            isLoading = false
        }

        private func finishImageImport(
            _ optimized: ImageOptimizationService.Result,
            id: String,
            noteID: String?
        ) {
            imageImportTasks.removeValue(forKey: id)
            guard loadedNoteID == noteID,
                  let textView,
                  let storage = textView.textStorage,
                  let placeholderRange = pendingImageRange(id: id, in: storage)
            else {
                return
            }

            let metadata = VaultResourcePolicy.ImageMetadata(
                width: optimized.width,
                height: optimized.height,
                frameCount: 1
            )
            let existingSources = currentAttachmentIDs().compactMap { imageSourcesByID[$0] }
            guard VaultResourcePolicy.canAddImage(
                byteCount: optimized.data.count,
                metadata: metadata,
                to: existingSources
            ) else {
                removeImagePlaceholder(id: id)
                parent.onError("This note has reached its safe image storage limit.")
                return
            }

            let attachmentID = UUID().uuidString
            let wrapper = FileWrapper(regularFileWithContents: optimized.data)
            wrapper.preferredFilename = "\(attachmentID).\(optimized.filenameExtension)"
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            attachmentIDsByObject[ObjectIdentifier(attachment)] = attachmentID
            imageSourcesByID[attachmentID] = VaultImageSource(
                id: attachmentID,
                data: optimized.data,
                typeIdentifier: optimized.typeIdentifier,
                filenameExtension: optimized.filenameExtension
            )

            let widthFraction = RichTextImageLayout.defaultWidthFraction
            imageDisplayWidths[attachmentID] = widthFraction
            setBounds(for: attachment, imageSize: metadata.size, widthFraction: widthFraction)

            let before = NSMutableAttributedString(attributedString: storage)
            before.deleteCharacters(in: placeholderRange)
            registerUndo(
                attributedString: before,
                imageDisplayWidths: imageDisplayWidths.filter { $0.key != attachmentID },
                selection: NSRange(location: min(placeholderRange.location, before.length), length: 0),
                actionName: "Insert Image"
            )
            textView.undoManager?.setActionName("Insert Image")

            isLoading = true
            storage.replaceCharacters(
                in: placeholderRange,
                with: NSAttributedString(attachment: attachment)
            )
            textView.setSelectedRange(NSRange(location: placeholderRange.location + 1, length: 0))
            isLoading = false
            emitChange()
            updateSelectionState()
        }

        private func failImageImport(id: String, message: String) {
            imageImportTasks.removeValue(forKey: id)
            removeImagePlaceholder(id: id)
            parent.onError(message)
        }

        private func removeImagePlaceholder(id: String) {
            guard let textView,
                  let storage = textView.textStorage,
                  let range = pendingImageRange(id: id, in: storage)
            else {
                return
            }
            isLoading = true
            storage.deleteCharacters(in: range)
            textView.setSelectedRange(NSRange(location: min(range.location, storage.length), length: 0))
            isLoading = false
        }

        private func pendingImageRange(id: String, in storage: NSAttributedString) -> NSRange? {
            var match: NSRange?
            storage.enumerateAttribute(
                .pendingImageImportID,
                in: NSRange(location: 0, length: storage.length)
            ) { value, range, stop in
                guard value as? String == id else { return }
                match = range
                stop.pointee = true
            }
            return match
        }

        func focusEditor() {
            guard let textView else {
                return
            }
            textView.window?.makeFirstResponder(textView)
        }

        func clearEditor() {
            imageImportTasks.values.forEach { $0.cancel() }
            imageImportTasks.removeAll(keepingCapacity: false)
            isLoading = true
            if let textView {
                textView.inputContext?.discardMarkedText()
                textView.unmarkText()
                if textView.window?.firstResponder === textView {
                    textView.window?.makeFirstResponder(nil)
                }
                textView.breakUndoCoalescing()
                textView.undoManager?.removeAllActions()
                textView.delegate = nil
                textView.textStorage?.setAttributedString(NSAttributedString())
            }
            imageDisplayWidths.removeAll(keepingCapacity: false)
            attachmentIDsByObject.removeAll(keepingCapacity: false)
            imageSourcesByID.removeAll(keepingCapacity: false)
            textView?.selectedImageCharacterIndex = nil
            formattingPreview = nil
            copiedFormatting = nil
            loadedNoteID = nil
            isLoading = false
        }

        func updateAttachmentBounds() {
            guard let textView, let storage = textView.textStorage else {
                return
            }

            let fullRange = NSRange(location: 0, length: storage.length)
            var didChangeBounds = false
            storage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let attachmentID = attachmentID(for: attachment),
                      let imageSize = imageSize(for: attachment)
                else {
                    return
                }

                let fraction = imageDisplayWidths[attachmentID]
                    ?? RichTextImageLayout.defaultWidthFraction
                didChangeBounds = setBounds(
                    for: attachment,
                    imageSize: imageSize,
                    widthFraction: fraction
                ) || didChangeBounds
            }
            if didChangeBounds {
                textView.layoutManager?.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
                textView.needsDisplay = true
            }
        }

        func scheduleAttachmentBoundsUpdate() {
            guard !isAttachmentBoundsUpdateScheduled else { return }
            isAttachmentBoundsUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isAttachmentBoundsUpdateScheduled = false
                self.updateAttachmentBounds()
            }
        }

        private func transformFonts(_ transform: (NSFont) -> NSFont) {
            performMutation(actionName: "Format Text") {
                self.transformFontsWithoutCommit(transform)
            }
        }

        private func applyAttribute(_ key: NSAttributedString.Key, value: Any) {
            performMutation(actionName: "Format Text") {
                self.applyAttributeWithoutCommit(key, value: value)
            }
        }

        private func transformFontsWithoutCommit(_ transform: (NSFont) -> NSFont) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            if selection.length == 0 {
                var attributes = textView.typingAttributes
                let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 19)
                attributes[.font] = transform(font)
                textView.typingAttributes = attributes
                return
            }

            storage.enumerateAttribute(.font, in: selection) { value, range, _ in
                let font = value as? NSFont ?? .systemFont(ofSize: 19)
                storage.addAttribute(.font, value: transform(font), range: range)
            }
        }

        private func applyAttributeWithoutCommit(_ key: NSAttributedString.Key, value: Any) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            if selection.length == 0 {
                var attributes = textView.typingAttributes
                attributes[key] = value
                textView.typingAttributes = attributes
            } else {
                storage.addAttribute(key, value: value, range: selection)
            }
        }

        private func previewFormatting(actionName: String, mutation: () -> Void) {
            guard let textView, let storage = textView.textStorage else { return }
            if let preview = formattingPreview {
                restorePreview(preview)
            } else {
                formattingPreview = FormattingPreview(
                    attributedString: NSAttributedString(attributedString: storage),
                    typingAttributes: textView.typingAttributes,
                    selection: textView.selectedRange(),
                    imageDisplayWidths: imageDisplayWidths,
                    actionName: actionName
                )
            }

            storage.beginEditing()
            mutation()
            normalizeSelection(in: textView, storage: storage)
            storage.endEditing()
            updateSelectionState()
        }

        private func restorePreview(_ preview: FormattingPreview) {
            guard let textView, let storage = textView.textStorage else { return }
            isLoading = true
            storage.setAttributedString(preview.attributedString)
            textView.typingAttributes = preview.typingAttributes
            textView.setSelectedRange(clampedRange(preview.selection, toLength: storage.length))
            imageDisplayWidths = preview.imageDisplayWidths
            isLoading = false
        }

        private func performMutation(actionName: String, mutation: () -> Void) {
            guard let textView, let storage = textView.textStorage else {
                return
            }

            cancelFormattingPreview()

            let before = NSAttributedString(attributedString: storage)
            let beforeWidths = imageDisplayWidths
            let beforeSelection = clampedRange(textView.selectedRange(), toLength: storage.length)
            registerUndo(
                attributedString: before,
                imageDisplayWidths: beforeWidths,
                selection: beforeSelection,
                actionName: actionName
            )
            textView.undoManager?.setActionName(actionName)

            storage.beginEditing()
            mutation()
            normalizeSelection(in: textView, storage: storage)
            storage.endEditing()
            emitChange()
            updateSelectionState()
        }

        private func registerUndo(
            attributedString: NSAttributedString,
            imageDisplayWidths: [String: Double],
            selection: NSRange,
            actionName: String
        ) {
            textView?.undoManager?.registerUndo(withTarget: self) { target in
                target.restore(
                    attributedString: attributedString,
                    imageDisplayWidths: imageDisplayWidths,
                    selection: selection,
                    actionName: actionName
                )
            }
        }

        private func restore(
            attributedString: NSAttributedString,
            imageDisplayWidths: [String: Double],
            selection: NSRange,
            actionName: String
        ) {
            guard let textView, let storage = textView.textStorage else {
                return
            }

            let current = NSAttributedString(attributedString: storage)
            let currentWidths = self.imageDisplayWidths
            let currentSelection = textView.selectedRange()
            textView.undoManager?.registerUndo(withTarget: self) { target in
                target.restore(
                    attributedString: current,
                    imageDisplayWidths: currentWidths,
                    selection: currentSelection,
                    actionName: actionName
                )
            }

            isLoading = true
            storage.setAttributedString(attributedString)
            self.imageDisplayWidths = imageDisplayWidths
            textView.setSelectedRange(clampedRange(selection, toLength: storage.length))
            updateAttachmentBounds()
            isLoading = false
            emitChange()
            updateSelectionState()
        }

        private func emitChange() {
            guard !isLoading,
                  let textView,
                  let storage = textView.textStorage
            else {
                return
            }

            let persistableStorage = NSMutableAttributedString(attributedString: storage)
            let persistableRange = NSRange(location: 0, length: persistableStorage.length)
            var pendingRanges: [NSRange] = []
            persistableStorage.enumerateAttribute(.pendingImageImportID, in: persistableRange) {
                value, range, _ in
                if value != nil {
                    pendingRanges.append(range)
                }
            }
            for range in pendingRanges.reversed() {
                persistableStorage.deleteCharacters(in: range)
            }

            guard let rtfdData = VaultRichTextDocument.encode(persistableStorage)
            else {
                return
            }

            let plainText = persistableStorage.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            let attachmentIDs = currentAttachmentIDs()
            let imageSources = attachmentIDs.compactMap { imageSourcesByID[$0] }
            guard VaultResourcePolicy.canPersistRichContent(
                body: plainText,
                rtfdByteCount: rtfdData.count,
                attachmentCount: attachmentIDs.count,
                imageSources: imageSources
            ) else {
                parent.onError("This note is too large to save safely.")
                return
            }
            parent.onChange(
                plainText,
                VaultRichContent(
                    rtfdData: rtfdData,
                    imageAttachmentIDs: attachmentIDs,
                    imageDisplayWidths: persistedImageDisplayWidths(),
                    imageSources: imageSources
                )
            )
        }

        private func scheduleSelectionStateUpdate() {
            DispatchQueue.main.async { [weak self] in
                self?.updateSelectionState()
            }
        }

        private func updateSelectionState() {
            guard let textView, let storage = textView.textStorage else {
                return
            }

            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            if selection != textView.selectedRange() {
                textView.setSelectedRange(selection)
            }
            let inspectionRange: NSRange
            if selection.length > 0 {
                inspectionRange = selection
            } else if storage.length > 0 {
                inspectionRange = NSRange(location: min(selection.location, storage.length - 1), length: 1)
            } else {
                inspectionRange = NSRange(location: 0, length: 0)
            }

            var fonts: [NSFont] = []
            var colors: [NSColor] = []
            if inspectionRange.length > 0 {
                storage.enumerateAttributes(in: inspectionRange) { attributes, _, _ in
                    if attributes[.attachment] == nil {
                        fonts.append(attributes[.font] as? NSFont ?? .systemFont(ofSize: 19))
                        colors.append(attributes[.foregroundColor] as? NSColor ?? .macPastebinPaperInk)
                    }
                }
            }

            if fonts.isEmpty {
                let attributes = textView.typingAttributes
                fonts = [attributes[.font] as? NSFont ?? .systemFont(ofSize: 19)]
                colors = [attributes[.foregroundColor] as? NSColor ?? .macPastebinPaperInk]
            }

            let fontManager = NSFontManager.shared
            let fontFamilies = fonts.map { $0.familyName ?? $0.fontName }
            let fontSizes = fonts.map { Double($0.pointSize) }
            let boldValues = fonts.map { fontManager.traits(of: $0).contains(.boldFontMask) }
            let italicValues = fonts.map { fontManager.traits(of: $0).contains(.italicFontMask) }
            let alignmentValues = paragraphAlignments(in: textView, storage: storage)

            parent.context.update(
                fontFamily: uniformValue(in: fontFamilies),
                fontSize: uniformValue(in: fontSizes),
                isBold: uniformValue(in: boldValues),
                isItalic: uniformValue(in: italicValues),
                textColor: colors.first ?? .macPastebinPaperInk,
                textAlignment: uniformValue(in: alignmentValues)
            )

            if let location = selectedAttachmentLocation(in: textView) {
                textView.selectedImageCharacterIndex = location
            } else {
                textView.selectedImageCharacterIndex = nil
            }
        }

        private func selectImage(at location: Int) {
            guard let textView,
                  let storage = textView.textStorage,
                  location >= 0,
                  location < storage.length,
                  storage.attribute(.attachment, at: location, effectiveRange: nil) is NSTextAttachment
            else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: location, length: 1))
            updateSelectionState()
        }

        private func deleteImage(at location: Int) {
            guard let textView,
                  let storage = textView.textStorage,
                  location >= 0,
                  location < storage.length,
                  let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment,
                  let attachmentID = attachmentID(for: attachment)
            else { return }

            textView.setSelectedRange(NSRange(location: location, length: 1))
            performMutation(actionName: "Delete Image") {
                storage.deleteCharacters(in: NSRange(location: location, length: 1))
                imageDisplayWidths.removeValue(forKey: attachmentID)
                textView.setSelectedRange(NSRange(location: min(location, storage.length), length: 0))
            }
        }

        func moveImage(from sourceLocation: Int, to proposedDestination: Int) {
            guard let textView,
                  let storage = textView.textStorage,
                  sourceLocation >= 0,
                  sourceLocation < storage.length,
                  storage.attribute(.attachment, at: sourceLocation, effectiveRange: nil) is NSTextAttachment
            else { return }

            let originalString = storage.string as NSString
            let safeDestination = min(max(proposedDestination, 0), originalString.length)
            let destinationParagraph = safeDestination == originalString.length
                ? originalString.length
                : originalString.paragraphRange(
                    for: NSRange(location: safeDestination, length: 0)
                ).location

            var removalRange = NSRange(location: sourceLocation, length: 1)
            if NSMaxRange(removalRange) < originalString.length,
               originalString.character(at: NSMaxRange(removalRange)) == 0x0A {
                removalRange.length += 1
            }
            guard !NSLocationInRange(destinationParagraph, removalRange) else { return }

            let attachment = NSMutableAttributedString(
                attributedString: storage.attributedSubstring(
                    from: NSRange(location: sourceLocation, length: 1)
                )
            )
            let leftAlignedStyle = NSMutableParagraphStyle()
            leftAlignedStyle.alignment = .left
            attachment.addAttribute(
                .paragraphStyle,
                value: leftAlignedStyle,
                range: NSRange(location: 0, length: attachment.length)
            )
            attachment.append(
                NSAttributedString(
                    string: "\n",
                    attributes: Self.defaultAttributes.merging([.paragraphStyle: leftAlignedStyle]) { _, new in new }
                )
            )

            var finalInsertionLocation = 0
            performMutation(actionName: "Move Image") {
                storage.deleteCharacters(in: removalRange)
                let adjustedDestination = destinationParagraph > removalRange.location
                    ? destinationParagraph - removalRange.length
                    : destinationParagraph
                let insertionLocation = min(max(adjustedDestination, 0), storage.length)
                finalInsertionLocation = insertionLocation
                storage.insert(attachment, at: insertionLocation)
                textView.setSelectedRange(NSRange(location: finalInsertionLocation, length: 1))
            }
            textView.setSelectedRange(NSRange(location: finalInsertionLocation, length: 1))
            updateSelectionState()
        }

        private func paragraphAlignments(
            in textView: NSTextView,
            storage: NSTextStorage
        ) -> [NSTextAlignment] {
            guard storage.length > 0 else {
                let style = textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle
                return [style?.alignment ?? .left]
            }

            let range = paragraphRange(in: textView, storage: storage)
            var alignments: [NSTextAlignment] = []
            storage.enumerateAttribute(.paragraphStyle, in: range) { value, _, _ in
                alignments.append((value as? NSParagraphStyle)?.alignment ?? .left)
            }
            return alignments.isEmpty ? [.left] : alignments
        }

        private func uniformValue(in values: [Bool]) -> Bool? {
            guard let first = values.first, values.allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }

        private func uniformValue<T: Equatable>(in values: [T]) -> T? {
            guard let first = values.first, values.allSatisfy({ $0 == first }) else {
                return nil
            }
            return first
        }

        private func assignAttachmentIdentifiers(_ savedIdentifiers: [String]) {
            guard let storage = textView?.textStorage else {
                return
            }

            var attachmentIndex = 0
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else {
                    return
                }

                let savedIdentifier = attachmentIndex < savedIdentifiers.count
                    ? savedIdentifiers[attachmentIndex]
                    : nil
                let wrapperIdentifier = attachment.fileWrapper?.preferredFilename.map {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                }
                attachmentIDsByObject[ObjectIdentifier(attachment)] = savedIdentifier
                    ?? wrapperIdentifier
                    ?? UUID().uuidString
                attachmentIndex += 1
            }
        }

        private func rebuildAttachmentsFromOriginalSources(_ savedIdentifiers: [String]) {
            guard let storage = textView?.textStorage else {
                return
            }

            let attachmentRanges = VaultRichTextDocument.attachmentLocations(in: storage)
                .map { NSRange(location: $0, length: 1) }

            for (index, range) in attachmentRanges.enumerated() where index < savedIdentifiers.count {
                let identifier = savedIdentifiers[index]
                guard let source = imageSourcesByID[identifier] else {
                    continue
                }
                let wrapper = FileWrapper(regularFileWithContents: source.data)
                wrapper.preferredFilename = "\(identifier).\(source.filenameExtension)"
                let attachment = NSTextAttachment(fileWrapper: wrapper)
                storage.replaceCharacters(in: range, with: NSAttributedString(attachment: attachment))
            }
        }

        private func persistedImageDisplayWidths() -> [String: Double] {
            guard let storage = textView?.textStorage else {
                return [:]
            }

            var attachmentIDs = Set<String>()
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let identifier = attachmentID(for: attachment)
                else {
                    return
                }
                attachmentIDs.insert(identifier)
            }

            return imageDisplayWidths.filter { attachmentIDs.contains($0.key) }
        }

        private func currentAttachmentIDs() -> [String] {
            guard let storage = textView?.textStorage else {
                return []
            }

            var identifiers: [String] = []
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.enumerateAttribute(.attachment, in: fullRange) { value, _, _ in
                guard let attachment = value as? NSTextAttachment,
                      let identifier = attachmentID(for: attachment)
                else {
                    return
                }
                identifiers.append(identifier)
            }
            return identifiers
        }

        private func selectedAttachment(in textView: NSTextView) -> (String, NSTextAttachment)? {
            guard let storage = textView.textStorage, storage.length > 0 else {
                return nil
            }

            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            let candidateLocations: [Int]
            if selection.length == 1 {
                candidateLocations = [selection.location]
            } else if selection.length > 1 {
                return nil
            } else {
                candidateLocations = [selection.location, selection.location - 1]
                    .filter { $0 >= 0 && $0 < storage.length }
            }

            for location in candidateLocations {
                if let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment,
                   let identifier = attachmentID(for: attachment) {
                    return (identifier, attachment)
                }
            }
            return nil
        }

        private func selectedAttachmentLocation(in textView: NSTextView) -> Int? {
            guard let storage = textView.textStorage, storage.length > 0 else { return nil }

            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            let candidateLocations: [Int]
            if selection.length == 1 {
                candidateLocations = [selection.location]
            } else if selection.length > 1 {
                return nil
            } else {
                candidateLocations = [selection.location, selection.location - 1]
                    .filter { $0 >= 0 && $0 < storage.length }
            }

            return candidateLocations.first {
                storage.attribute(.attachment, at: $0, effectiveRange: nil) is NSTextAttachment
            }
        }

        private func attachmentID(for attachment: NSTextAttachment) -> String? {
            let objectIdentifier = ObjectIdentifier(attachment)
            if let identifier = attachmentIDsByObject[objectIdentifier] {
                return identifier
            }

            let wrapperIdentifier = attachment.fileWrapper?.preferredFilename.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
            let identifier = wrapperIdentifier?.isEmpty == false ? wrapperIdentifier! : UUID().uuidString
            attachmentIDsByObject[objectIdentifier] = identifier
            return identifier
        }

        private func imageSize(for attachment: NSTextAttachment) -> NSSize? {
            guard let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents,
                  let metadata = try? VaultResourcePolicy.imageMetadata(for: data)
            else {
                return nil
            }
            return metadata.size
        }

        @discardableResult
        private func setBounds(
            for attachment: NSTextAttachment,
            imageSize: NSSize,
            widthFraction: Double
        ) -> Bool {
            let displaySize = RichTextImageLayout.displaySize(
                for: imageSize,
                containerWidth: textContainerWidth(),
                widthFraction: widthFraction
            )
            let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents
            let image = data.flatMap(NSImage.init(data:))
            return RichTextImageLayout.applyDisplaySize(
                displaySize,
                to: attachment,
                image: image
            )
        }

        private func normalizeSelection(in textView: NSTextView, storage: NSTextStorage) {
            let selection = clampedRange(textView.selectedRange(), toLength: storage.length)
            if selection != textView.selectedRange() {
                textView.setSelectedRange(selection)
            }
        }

        private func clampedRange(_ range: NSRange, toLength length: Int) -> NSRange {
            let location = min(range.location, length)
            return NSRange(location: location, length: min(range.length, length - location))
        }

        private func textContainerWidth() -> CGFloat {
            guard let textView else {
                return 600
            }
            let viewportWidth = textView.enclosingScrollView?.contentSize.width ?? textView.bounds.width
            let availableWidth = min(textView.bounds.width, viewportWidth)
            let linePadding = (textView.textContainer?.lineFragmentPadding ?? 0) * 2
            return max(availableWidth - (textView.textContainerInset.width * 2) - linePadding, 1)
        }
    }
}

final class MacPastebinTextView: NSTextView {
    var selectedImageCharacterIndex: Int? {
        didSet {
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var onSelectImage: ((Int) -> Void)?
    var onDeleteImage: ((Int) -> Void)?
    var onMoveImage: ((Int, Int) -> Void)?
    var onViewportWidthChange: (() -> Void)?
    var onFormattingCommand: ((EditorFormattingCommand) -> Void)?

    private var pendingImageDrag: PendingImageDrag?
    private var imageDropCharacterIndex: Int? {
        didSet { needsDisplay = true }
    }
    private var imageHoverTrackingArea: NSTrackingArea?
    private var hoveredImageCharacterIndex: Int?
    private var displayedDeleteImageCharacterIndex: Int?
    private var deleteButtonOpacity: CGFloat = 0
    private var deleteButtonFadeTimer: Timer?

    deinit {
        deleteButtonFadeTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)

        guard newSize.width > 0, abs(newSize.width - oldWidth) > 0.5 else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onViewportWidthChange?()
        }
    }

    override func updateTrackingAreas() {
        if let imageHoverTrackingArea {
            removeTrackingArea(imageHoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(trackingArea)
        imageHoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        updateHoveredImage(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateHoveredImage(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        updateHoveredImage(at: nil)
        super.mouseExited(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else {
            return
        }
        insertText(string, replacementRange: selectedRange())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let character = event.charactersIgnoringModifiers?.lowercased()
        let command: EditorFormattingCommand?

        switch (flags, character) {
        case ([.command], "b"): command = .toggleBold
        case ([.command], "i"): command = .toggleItalic
        case ([.command], "u"): command = .toggleUnderline
        case ([.command, .shift], "x"): command = .toggleStrikethrough
        case ([.command, .option], "0"): command = .heading(0)
        case ([.command, .option], "1"): command = .heading(1)
        case ([.command, .option], "2"): command = .heading(2)
        case ([.command, .option], "3"): command = .heading(3)
        case ([.command, .option], "c"): command = .copyFormatting
        case ([.command, .option], "v"): command = .pasteFormatting
        case ([.command], "\\"): command = .clearFormatting
        case ([.command, .shift], "."): command = .increaseFontSize
        case ([.command, .shift], ","): command = .decreaseFontSize
        case ([.command], ","): command = .subscriptText
        case ([.command], "."): command = .superscriptText
        case ([.command, .shift], "l"): command = .alignLeft
        case ([.command, .shift], "e"): command = .alignCenter
        case ([.command, .shift], "r"): command = .alignRight
        case ([.command, .shift], "j"): command = .justify
        case ([.command, .shift], "8"): command = .bulletedList
        case ([.command, .shift], "7"): command = .numberedList
        default: command = nil
        }

        guard let command else {
            return super.performKeyEquivalent(with: event)
        }
        onFormattingCommand?(command)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 48, isSelectionInList else {
            super.keyDown(with: event)
            return
        }
        let isOutdent = event.modifierFlags.contains(.shift)
        onFormattingCommand?(isOutdent ? .outdent : .indent)
    }

    private var isSelectionInList: Bool {
        guard let textStorage, textStorage.length > 0 else { return false }
        let location = min(selectedRange().location, textStorage.length - 1)
        let style = textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
        return style?.textLists.isEmpty == false
    }

    override func draw(_ dirtyRect: NSRect) {
        if let textStorage {
            let selection = selectedRange()
            let location = min(selection.location, textStorage.length)
            let safeSelection = NSRange(
                location: location,
                length: min(selection.length, textStorage.length - location)
            )
            if selection != safeSelection {
                setSelectedRange(safeSelection)
            }
        }
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()

        if let location = displayedDeleteImageCharacterIndex,
           deleteButtonOpacity > 0,
           let imageRect = attachmentRect(at: location) {
            let closeRect = closeButtonRect(for: imageRect)
            NSColor.systemRed.withAlphaComponent(deleteButtonOpacity).setFill()
            NSBezierPath(ovalIn: closeRect).fill()
            NSColor.white.withAlphaComponent(deleteButtonOpacity).setStroke()
            let inset = closeRect.insetBy(dx: 6.5, dy: 6.5)
            let closePath = NSBezierPath()
            closePath.lineWidth = 2
            closePath.lineCapStyle = .round
            closePath.move(to: NSPoint(x: inset.minX, y: inset.minY))
            closePath.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            closePath.move(to: NSPoint(x: inset.maxX, y: inset.minY))
            closePath.line(to: NSPoint(x: inset.minX, y: inset.maxY))
            closePath.stroke()
        }

        if imageDropCharacterIndex != nil {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: textContainerOrigin.x,
                    y: insertionIndicatorY,
                    width: max(textContainerWidth, 32),
                    height: 3
                ),
                xRadius: 1.5,
                yRadius: 1.5
            ).fill()
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if let location = hoveredImageCharacterIndex,
           let imageRect = attachmentRect(at: location) {
            if closeButtonHitRect(for: imageRect).contains(point) {
                updateHoveredImage(at: nil)
                onDeleteImage?(location)
                return
            }
        }

        if let location = attachmentLocation(at: point) {
            onSelectImage?(location)
            pendingImageDrag = PendingImageDrag(
                sourceLocation: location,
                initialPoint: point,
                destinationLocation: location,
                isDragging: false
            )
            return
        }

        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = pendingImageDrag else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if !drag.isDragging {
            let distance = hypot(point.x - drag.initialPoint.x, point.y - drag.initialPoint.y)
            guard distance >= 4 else { return }
            drag.isDragging = true
        }

        autoscroll(with: event)
        drag.destinationLocation = characterIndexForInsertion(at: point)
        pendingImageDrag = drag
        imageDropCharacterIndex = drag.destinationLocation
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = pendingImageDrag {
            pendingImageDrag = nil
            imageDropCharacterIndex = nil
            NSCursor.arrow.set()
            if drag.isDragging {
                onMoveImage?(drag.sourceLocation, drag.destinationLocation)
            }
            return
        }
        super.mouseUp(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let storage = textStorage else { return }
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: [.longestEffectiveRangeNotRequired]
        ) { value, range, _ in
            guard value is NSTextAttachment,
                  let imageRect = attachmentRect(at: range.location)
            else { return }
            addCursorRect(imageRect, cursor: .openHand)
            addCursorRect(closeButtonHitRect(for: imageRect), cursor: .pointingHand)
        }
    }

    private func updateHoveredImage(at point: NSPoint?) {
        let location = point.flatMap(attachmentLocation(at:))
        guard hoveredImageCharacterIndex != location else { return }

        hoveredImageCharacterIndex = location
        if let location {
            displayedDeleteImageCharacterIndex = location
            animateDeleteButton(to: 1)
        } else {
            animateDeleteButton(to: 0)
        }
        window?.invalidateCursorRects(for: self)
    }

    private func animateDeleteButton(to targetOpacity: CGFloat) {
        deleteButtonFadeTimer?.invalidate()

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            deleteButtonOpacity = targetOpacity
            if targetOpacity == 0 {
                displayedDeleteImageCharacterIndex = nil
            }
            needsDisplay = true
            return
        }

        let initialOpacity = deleteButtonOpacity
        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = 0.16
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let progress = min(max(elapsed / duration, 0), 1)
            let easedProgress = 1 - pow(1 - progress, 3)
            self.deleteButtonOpacity = initialOpacity
                + ((targetOpacity - initialOpacity) * CGFloat(easedProgress))
            self.needsDisplay = true

            if progress >= 1 {
                timer.invalidate()
                self.deleteButtonFadeTimer = nil
                if targetOpacity == 0 {
                    self.displayedDeleteImageCharacterIndex = nil
                }
            }
        }
        deleteButtonFadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func attachmentLocation(at point: NSPoint) -> Int? {
        guard let storage = textStorage else { return nil }
        var match: Int?
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length),
            options: [.longestEffectiveRangeNotRequired]
        ) { value, range, stop in
            guard value is NSTextAttachment,
                  let rect = attachmentRect(at: range.location),
                  rect.contains(point)
            else { return }
            match = range.location
            stop.pointee = true
        }
        return match
    }

    private func attachmentRect(at characterIndex: Int) -> NSRect? {
        guard let layoutManager,
              let textContainer,
              let storage = textStorage,
              characterIndex >= 0,
              characterIndex < storage.length,
              storage.attribute(.attachment, at: characterIndex, effectiveRange: nil) is NSTextAttachment
        else { return nil }

        let characterRange = NSRange(location: characterIndex, length: 1)
        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    private func closeButtonRect(for imageRect: NSRect) -> NSRect {
        // AppKit displays its attachment-options affordance in the upper-right
        // corner on hover. Mirror the destructive action on the opposite side
        // so both controls remain visible and easy to distinguish.
        NSRect(x: imageRect.minX + 6, y: imageRect.minY + 8, width: 24, height: 24)
    }

    private func closeButtonHitRect(for imageRect: NSRect) -> NSRect {
        closeButtonRect(for: imageRect).insetBy(dx: -4, dy: -4)
    }

    private var insertionIndicatorY: CGFloat {
        guard let characterIndex = imageDropCharacterIndex,
              let layoutManager,
              let storage = textStorage,
              storage.length > 0
        else { return textContainerOrigin.y }

        let isAtDocumentEnd = characterIndex >= storage.length
        let safeCharacterIndex = min(characterIndex, storage.length - 1)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: safeCharacterIndex)
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return textContainerOrigin.y + (isAtDocumentEnd ? lineRect.maxY : lineRect.minY) - 2
    }

    private var textContainerWidth: CGFloat {
        guard let textContainer else { return 32 }
        return textContainer.size.width - (textContainer.lineFragmentPadding * 2)
    }

    private struct PendingImageDrag {
        let sourceLocation: Int
        let initialPoint: NSPoint
        var destinationLocation: Int
        var isDragging: Bool
    }
}

extension NSColor {
    static let macPastebinPaperInk = NSColor(
        calibratedRed: 0.035,
        green: 0.045,
        blue: 0.055,
        alpha: 1
    )
}
