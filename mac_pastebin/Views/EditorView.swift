import SwiftUI

struct EditorView: View {
    private enum FocusArea {
        case noteList
        case title
        case editor
    }

    @EnvironmentObject private var appState: AppState
    @State private var notePendingRename: VaultNote?
    @State private var renameTitle = ""
    @State private var notePendingDeletion: VaultNote?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var titleEditingNoteID: String?
    @State private var fontFamilyDraft = NSFont.systemFont(ofSize: 19).familyName ?? "System Font"
    @State private var fontSizeDraft = "19"
    @StateObject private var richTextContext = RichTextEditorContext()
    @FocusState private var focusedArea: FocusArea?

    var body: some View {
        ZStack {
            VStack(spacing: MacPastebinLayout.sectionSpacing) {
                toolbar

                HStack(alignment: .top, spacing: 20) {
                    notesSidebar
                    editorSurface
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, MacPastebinLayout.outerPadding)
            .padding(.top, MacPastebinLayout.outerPadding)
            .padding(.bottom, 24)
        }
        .onAppear {
            focusedArea = .editor
            titleDraft = selectedNoteTitle
            DispatchQueue.main.async {
                richTextContext.focusEditor()
            }
        }
        .onDisappear {
            richTextContext.clear()
        }
        .onChange(of: focusedArea) { oldFocus, newFocus in
            if oldFocus == .title && newFocus != .title {
                commitTitleEditing()
            }
        }
        .onChange(of: appState.selectedNoteID) { _, _ in
            commitTitleEditing()
            titleDraft = selectedNoteTitle
            if focusedArea != .noteList {
                DispatchQueue.main.async {
                    richTextContext.focusEditor()
                }
            }
        }
        .onChange(of: richTextContext.fontFamily) { _, family in
            fontFamilyDraft = family ?? ""
        }
        .onChange(of: richTextContext.fontSize) { _, size in
            guard let size else {
                fontSizeDraft = "—"
                return
            }
            fontSizeDraft = String(format: size.rounded() == size ? "%.0f" : "%.1f", size)
        }
        .onMoveCommand { direction in
            guard focusedArea == .noteList else {
                return
            }

            switch direction {
            case .up:
                appState.selectPreviousNote()
            case .down:
                appState.selectNextNote()
            default:
                break
            }
        }
        .sheet(item: $notePendingRename) { note in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename Note")
                    .font(.headline)

                TextField("Title", text: $renameTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        commitPendingRename(note)
                    }

                HStack {
                    Spacer()

                    Button("Cancel") {
                        notePendingRename = nil
                    }

                    Button("Rename") {
                        commitPendingRename(note)
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 320)
        }
        .alert("Delete Note?", isPresented: deleteConfirmationBinding, presenting: notePendingDeletion) { note in
            Button("Cancel", role: .cancel) {
                notePendingDeletion = nil
            }

            Button("Delete", role: .destructive) {
                appState.deleteNote(id: note.id)
                notePendingDeletion = nil
            }
        } message: { note in
            Text("This removes \"\(note.title)\" from the vault.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Spacer()

            statusPill
            autoSavePill
            toolbarIconButton(systemImage: "doc.on.doc", help: "Copy note text") {
                appState.copySelectedNoteBodyToPasteboard()
            }
            toolbarIconButton(systemImage: "square.and.arrow.down", help: "Save vault") {
                appState.saveEditorText()
            }
            toolbarIconButton(systemImage: "lock", help: "Lock vault") {
                appState.lock()
            }

            Button("Notes") {
                focusedArea = .noteList
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            Button("Editor") {
                focusedArea = .editor
                richTextContext.focusEditor()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)

            Button("Save") {
                appState.saveEditorText()
            }
            .keyboardShortcut("s", modifiers: .command)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var statusPill: some View {
        Label(statusText, systemImage: "checkmark")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.88))
            .frame(height: 48)
            .padding(.horizontal, 20)
            .puffyGlassSurface(cornerRadius: 20, tintOpacity: 0.34)
    }

    private var autoSavePill: some View {
        Button {
            appState.setAutoSaveEnabled(!appState.isAutoSaveEnabled)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .fill(appState.isAutoSaveEnabled ? MacPastebinPalette.sage : Color.white.opacity(0.82))
                    .frame(width: 18, height: 18)
                    .overlay {
                        if appState.isAutoSaveEnabled {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.72))
                        }
                    }

                Text("Auto Save")
                    .font(.system(size: 16, weight: .medium))
            }
            .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.84))
            .frame(height: 44)
            .padding(.horizontal, 17)
        }
        .buttonStyle(PuffyGlassButtonStyle(cornerRadius: 16, tintOpacity: 0.30))
        .help("Toggle auto save")
        .accessibilityValue(appState.isAutoSaveEnabled ? "On" : "Off")
    }

    private func toolbarIconButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.72))
                .frame(width: 46, height: 46)
        }
        .buttonStyle(PuffyGlassButtonStyle(cornerRadius: 16, tintOpacity: 0.30))
        .help(help)
        .accessibilityLabel(help)
    }

    private var notesSidebar: some View {
        VStack(spacing: 20) {
            HStack(alignment: .center) {
                Text("Notes")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.86))

                Spacer()

                Button {
                    appState.createNote()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.78))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(PuffyGlassButtonStyle(cornerRadius: 15, tintOpacity: 0.30))
                .help("New note")
                .accessibilityLabel("New note")
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(appState.notes) { note in
                        Button {
                            appState.selectNote(id: note.id)
                            focusedArea = .editor
                        } label: {
                            noteRow(for: note)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Rename") {
                                notePendingRename = note
                                renameTitle = note.title
                            }

                            Button("Delete", role: .destructive) {
                                notePendingDeletion = note
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focusedArea, equals: .noteList)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .padding(.bottom, 22)
        .frame(width: MacPastebinLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .liquidGlassSurface(cornerRadius: MacPastebinLayout.panelRadius, tintOpacity: 0.26)
    }

    private func noteRow(for note: VaultNote) -> some View {
        let isSelected = note.id == appState.selectedNoteID

        return HStack(spacing: 12) {
            Image(systemName: "doc")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(isSelected ? 0.78 : 0.62))
                .frame(width: 22)

            Text(note.title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.clear)
                    .glassEffect(
                        .regular.tint(MacPastebinPalette.glassTintElevated.opacity(0.36)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    }
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.44), lineWidth: 1)
            }
        }
    }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                editableTitleView

                Spacer()

                Text(wordCountLabel)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.70))
            }
            .padding(.horizontal, 26)
            .frame(height: 78)

            formattingToolbar

            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(MacPastebinPalette.paper)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.58), lineWidth: 1)
                    }

                RichTextEditor(
                    noteID: appState.selectedNoteID,
                    plainText: appState.selectedNoteBody,
                    richContent: appState.selectedNoteRichContent,
                    context: richTextContext,
                    onChange: { body, richContent in
                        appState.updateSelectedNoteContent(body: body, richContent: richContent)
                    },
                    onError: { message in
                        appState.reportEditorError(message)
                    },
                    onFocus: {
                        focusedArea = .editor
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassSurface(cornerRadius: MacPastebinLayout.panelRadius, tintOpacity: 0.28)
    }

    private var formattingToolbar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
            HoverFormattingPicker(
                title: fontFamilyDraft.isEmpty ? "Mixed fonts" : fontFamilyDraft,
                accessibilityLabel: "Font family",
                values: NSFontManager.shared.availableFontFamilies.sorted(),
                width: 190,
                preview: richTextContext.previewFontFamily,
                commit: { family in
                    fontFamilyDraft = family
                    richTextContext.commitFormattingPreview()
                },
                cancel: richTextContext.cancelFormattingPreview,
                row: { family in
                    Text(family)
                        .font(.custom(family, size: 13))
                }
            )

            HoverFormattingPicker(
                title: fontSizeDraft,
                accessibilityLabel: "Font size",
                values: [8, 9, 10, 11, 12, 14, 16, 18, 19, 20, 24, 28, 32, 36, 48, 64, 72, 96, 120, 144],
                width: 66,
                preview: { richTextContext.previewFontSize(Double($0)) },
                commit: { size in
                    fontSizeDraft = "\(size)"
                    richTextContext.commitFormattingPreview()
                },
                cancel: richTextContext.cancelFormattingPreview,
                row: { size in Text("\(size)") }
            )

            formattingButton(
                systemImage: richTextContext.isBold == nil ? "bold" : "bold",
                help: richTextContext.isBold == nil ? "Bold (mixed selection)" : "Bold",
                isActive: richTextContext.isBold == true,
                action: richTextContext.toggleBold
            )
            .keyboardShortcut("b", modifiers: .command)

            formattingButton(
                systemImage: "italic",
                help: richTextContext.isItalic == nil ? "Italic (mixed selection)" : "Italic",
                isActive: richTextContext.isItalic == true,
                action: richTextContext.toggleItalic
            )
            .keyboardShortcut("i", modifiers: .command)

            HoverColorPicker(
                selectedColor: richTextContext.textColor,
                preview: richTextContext.previewTextColor,
                commit: { _ in richTextContext.commitFormattingPreview() },
                cancel: richTextContext.cancelFormattingPreview
            )
            .help("Font color")

            Divider()
                .frame(height: 24)

            formattingButton(
                systemImage: "photo.badge.plus",
                help: "Insert image",
                isActive: false,
                action: richTextContext.insertImage
            )

            Divider()
                .frame(height: 24)

            formattingButton(
                systemImage: "text.alignleft",
                help: "Align left (Command-Shift-L)",
                isActive: richTextContext.textAlignment == .left,
                action: richTextContext.alignLeft
            )

            formattingButton(
                systemImage: "text.aligncenter",
                help: "Align center (Command-Shift-E)",
                isActive: richTextContext.textAlignment == .center,
                action: richTextContext.alignCenter
            )

            formattingButton(
                systemImage: "text.alignright",
                help: "Align right (Command-Shift-R)",
                isActive: richTextContext.textAlignment == .right,
                action: richTextContext.alignRight
            )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.34))
                .frame(height: 1)
        }
    }

    private func formattingButton(
        systemImage: String,
        help: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.78))
                .frame(width: 34, height: 34)
                .background(
                    isActive ? MacPastebinPalette.sage.opacity(0.55) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var editableTitleView: some View {
        if isEditingTitle {
            TextField("Title", text: $titleDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.92))
                .tint(MacPastebinPalette.paperInk.opacity(0.78))
                .focused($focusedArea, equals: .title)
                .onSubmit(commitTitleEditing)
                .frame(minWidth: 220)
        } else {
            Button {
                beginTitleEditing()
            } label: {
                HStack(spacing: 8) {
                    Text(selectedNoteTitle)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.92))
                        .lineLimit(1)

                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MacPastebinPalette.paperInk.opacity(0.50))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit title")
        }
    }

    private var selectedNoteTitle: String {
        appState.notes.first(where: { $0.id == appState.selectedNoteID })?.title ?? "Untitled"
    }

    private var statusText: String {
        guard let message = appState.editorStatusMessage else {
            return "Saved"
        }

        return message.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private var wordCountLabel: String {
        let words = appState.selectedNoteBody
            .split { $0.isWhitespace || $0.isNewline }
            .count

        return words == 1 ? "1 word" : "\(words) words"
    }

    private func beginTitleEditing() {
        titleDraft = selectedNoteTitle
        titleEditingNoteID = appState.selectedNoteID
        isEditingTitle = true
        focusedArea = .title
    }

    private func commitTitleEditing() {
        guard isEditingTitle else {
            return
        }

        isEditingTitle = false

        guard let noteID = titleEditingNoteID else {
            return
        }
        titleEditingNoteID = nil
        appState.renameNote(id: noteID, title: titleDraft)
        titleDraft = selectedNoteTitle
    }

    private func commitPendingRename(_ note: VaultNote) {
        appState.renameNote(id: note.id, title: renameTitle)
        notePendingRename = nil
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(
            get: { notePendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    notePendingDeletion = nil
                }
            }
        )
    }
}

private struct HoverFormattingPicker<Value: Hashable, Row: View>: View {
    let title: String
    let accessibilityLabel: String
    let values: [Value]
    let width: CGFloat
    let preview: (Value) -> Void
    let commit: (Value) -> Void
    let cancel: () -> Void
    @ViewBuilder let row: (Value) -> Row

    @State private var isPresented = false
    @State private var hoveredValue: Value?
    @State private var keyboardIndex: Int?

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(width: width, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(values, id: \.self) { value in
                                Button {
                                    preview(value)
                                    commit(value)
                                    hoveredValue = nil
                                    isPresented = false
                                } label: {
                                    row(value)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .frame(height: 30)
                                        .background(
                                            highlightedValue == value ? Color.accentColor.opacity(0.16) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(value)
                                .onHover { isHovering in
                                    if isHovering {
                                        keyboardIndex = nil
                                        hoveredValue = value
                                        preview(value)
                                    } else if hoveredValue == value {
                                        hoveredValue = nil
                                        cancel()
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(width: max(width, 150), height: min(CGFloat(values.count * 32 + 12), 360))
                    .onAppear {
                        keyboardIndex = values.firstIndex { String(describing: $0) == title }
                        if let highlightedValue {
                            proxy.scrollTo(highlightedValue, anchor: .center)
                        }
                    }

                    Button("Apply") {
                        guard let highlightedValue else { return }
                        preview(highlightedValue)
                        commit(highlightedValue)
                        self.hoveredValue = nil
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .disabled(highlightedValue == nil)
                }
                .focusable()
                .onMoveCommand { direction in
                    guard !values.isEmpty else { return }
                    let current = keyboardIndex ?? -1
                    switch direction {
                    case .down:
                        keyboardIndex = min(current + 1, values.count - 1)
                    case .up:
                        keyboardIndex = max(current < 0 ? values.count - 1 : current - 1, 0)
                    default:
                        return
                    }
                    hoveredValue = nil
                    if let keyboardIndex {
                        let value = values[keyboardIndex]
                        preview(value)
                        proxy.scrollTo(value, anchor: .center)
                    }
                }
                .onExitCommand {
                    isPresented = false
                }
                .onDisappear {
                    hoveredValue = nil
                    keyboardIndex = nil
                    cancel()
                }
            }
        }
    }

    private var highlightedValue: Value? {
        hoveredValue ?? keyboardIndex.map { values[$0] }
    }
}

private struct HoverColorPicker: View {
    private struct Choice: Identifiable {
        let id: String
        let name: String
        let color: NSColor
    }

    let selectedColor: NSColor
    let preview: (NSColor) -> Void
    let commit: (NSColor) -> Void
    let cancel: () -> Void

    @State private var isPresented = false
    @State private var hoveredID: String?

    private let choices = [
        Choice(id: "ink", name: "Ink", color: .macPastebinPaperInk),
        Choice(id: "black", name: "Black", color: .black),
        Choice(id: "gray", name: "Gray", color: .systemGray),
        Choice(id: "red", name: "Red", color: .systemRed),
        Choice(id: "orange", name: "Orange", color: .systemOrange),
        Choice(id: "yellow", name: "Yellow", color: .systemYellow),
        Choice(id: "green", name: "Green", color: .systemGreen),
        Choice(id: "blue", name: "Blue", color: .systemBlue),
        Choice(id: "purple", name: "Purple", color: .systemPurple),
        Choice(id: "pink", name: "Pink", color: .systemPink)
    ]

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "character")
                    .font(.system(size: 14, weight: .semibold))
                Rectangle()
                    .fill(Color(nsColor: selectedColor))
                    .frame(width: 18, height: 3)
            }
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Font color")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34)), count: 5), spacing: 8) {
                    ForEach(choices) { choice in
                        Button {
                            preview(choice.color)
                            commit(choice.color)
                            hoveredID = nil
                            isPresented = false
                        } label: {
                            Circle()
                                .fill(Color(nsColor: choice.color))
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                                }
                                .padding(hoveredID == choice.id ? 2 : 5)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .help(choice.name)
                        .onHover { isHovering in
                            if isHovering {
                                hoveredID = choice.id
                                preview(choice.color)
                            } else if hoveredID == choice.id {
                                hoveredID = nil
                                cancel()
                            }
                        }
                    }
                }
                .padding(10)

                Button("Apply") {
                    guard let choice = choices.first(where: { $0.id == hoveredID }) else { return }
                    commit(choice.color)
                    hoveredID = nil
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .disabled(hoveredID == nil)
            }
            .onDisappear {
                hoveredID = nil
                cancel()
            }
        }
    }
}
