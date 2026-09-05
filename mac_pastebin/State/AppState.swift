import AppKit
import Combine
import CryptoKit
import Foundation

enum LockState {
    case locked
    case unlocked
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var lockState: LockState = .locked
    @Published private(set) var vaultDirectoryExists = false
    @Published private(set) var vaultFileExists = false
    @Published private(set) var vaultNeedsCreation = true
    @Published private(set) var canReplaceCorruptedVault = false
    @Published private(set) var archivedVaults: [VaultService.ArchivedVault] = []
    @Published private(set) var notes: [VaultNote] = []
    @Published private(set) var selectedNoteID: String?
    @Published private(set) var isAutoSaveEnabled = false
    @Published private(set) var credentialResetGeneration: UInt64 = 0
    @Published var authenticationErrorMessage: String?
    @Published var editorStatusMessage: String?

    private let vaultService: VaultService
    private var derivedKey: SymmetricKey?
    // A failed disk write must not destroy edits or keep plaintext unlocked.
    // This snapshot uses the vault key, which is discarded on lock as usual.
    private var pendingRecovery: EncryptedPayload?
    private var autoSaveTask: Task<Void, Never>?
    private var hasUnsavedChanges = false
    private var copiedPasteboardChangeCount: Int?
    private let autoSaveDelayNanoseconds: UInt64 = 900_000_000
    private static let clearClipboardOnLock = false

    init(vaultService: VaultService? = nil) {
        self.vaultService = vaultService ?? VaultService()
        runDebugSelfChecks()
        prepareVaultFile()
    }

    var isLocked: Bool {
        lockState == .locked
    }

    func lock() {
        endActiveTextInputSessions()
        credentialResetGeneration &+= 1
        autoSaveTask?.cancel()
        autoSaveTask = nil

        if lockState == .unlocked, hasUnsavedChanges {
            if !saveCurrentPayload() {
                do {
                    guard let derivedKey else { return }
                    let data = try PropertyListEncoder().encode(currentPayload())
                    // Ensure recovery is decodable before clearing the live document.
                    _ = try PropertyListDecoder().decode(VaultPayload.self, from: data)
                    pendingRecovery = try CryptoService().encrypt(data, using: derivedKey)
                } catch {
                    editorStatusMessage = "Could not safely lock. Save your changes and try again."
                    return
                }
            }
        }

        if pendingRecovery != nil {
            authenticationErrorMessage = "Changes could not be saved. Keep this app open, then unlock to recover them."
        }
        if Self.clearClipboardOnLock {
            clearSensitivePasteboardIfUnchanged()
        }
        derivedKey = nil
        notes = []
        selectedNoteID = nil
        hasUnsavedChanges = false
        editorStatusMessage = nil
        lockState = .locked
    }

    private func endActiveTextInputSessions() {
        Self.endActiveTextInputSessions(in: NSApp.windows)
    }

    static func endActiveTextInputSessions(in windows: [NSWindow]) {
        for window in windows {
            if let textView = window.firstResponder as? NSTextView {
                textView.inputContext?.discardMarkedText()
                textView.unmarkText()
            }
            window.makeFirstResponder(nil)
        }
    }

    func createOrUnlockVault(password: String) {
        authenticationErrorMessage = nil
        canReplaceCorruptedVault = false

        do {
            let unlockResult: VaultService.VaultUnlockResult
            if vaultNeedsCreation {
                unlockResult = try vaultService.createVault(password: password)
            } else {
                unlockResult = try vaultService.unlockVault(password: password)
            }

            derivedKey = unlockResult.key
            if let pendingRecovery {
                let data = try CryptoService().decrypt(pendingRecovery, using: unlockResult.key)
                loadPayloadIntoMemory(try PropertyListDecoder().decode(VaultPayload.self, from: data))
                hasUnsavedChanges = true
                editorStatusMessage = "Recovered unsaved changes. Save again."
            } else {
                loadPayloadIntoMemory(unlockResult.payload)
                hasUnsavedChanges = false
                editorStatusMessage = nil
            }
            lockState = .unlocked
            refreshVaultStatus()
        } catch {
            derivedKey = nil
            notes = []
            selectedNoteID = nil
            editorStatusMessage = nil
            lockState = .locked
            authenticationErrorMessage = authenticationErrorMessage(for: error)
            canReplaceCorruptedVault = isRecoverableCorruptedVaultError(error)
        }
    }

    func replaceCorruptedVaultAfterConfirmation() {
        guard pendingRecovery == nil else {
            authenticationErrorMessage = "Unlock and save recovered changes before changing vaults."
            return
        }
        derivedKey = nil
        notes = []
        selectedNoteID = nil
        editorStatusMessage = nil
        lockState = .locked

        do {
            _ = try vaultService.moveCurrentVaultAsideForReplacement()
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Corrupted vault moved aside. Create a new vault."
        } catch {
            refreshVaultStatus()
            canReplaceCorruptedVault = isRecoverableCorruptedVaultError(error)
            authenticationErrorMessage = "Could not replace corrupted vault."
        }
    }

    func startNewVaultAfterForgettingPassword() {
        guard pendingRecovery == nil else {
            authenticationErrorMessage = "Unlock and save recovered changes before changing vaults."
            return
        }
        derivedKey = nil
        notes = []
        selectedNoteID = nil
        editorStatusMessage = nil
        lockState = .locked

        do {
            _ = try vaultService.moveCurrentVaultAsideForNewVault()
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Previous vault moved aside. Create a new vault."
        } catch {
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Could not start a new vault."
        }
    }

    func restoreArchivedVault(id: String) {
        guard pendingRecovery == nil else {
            authenticationErrorMessage = "Unlock and save recovered changes before changing vaults."
            return
        }
        derivedKey = nil
        notes = []
        selectedNoteID = nil
        editorStatusMessage = nil
        lockState = .locked

        do {
            try vaultService.restoreArchivedVault(id: id)
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Archived vault restored. Unlock with that vault password."
        } catch {
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Could not restore archived vault."
        }
    }

    func deleteArchivedVault(id: String) {
        guard pendingRecovery == nil else {
            authenticationErrorMessage = "Unlock and save recovered changes before changing vaults."
            return
        }
        derivedKey = nil
        notes = []
        selectedNoteID = nil
        editorStatusMessage = nil
        lockState = .locked

        do {
            try vaultService.deleteArchivedVault(id: id)
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Archived vault deleted."
        } catch {
            refreshVaultStatus()
            canReplaceCorruptedVault = false
            authenticationErrorMessage = "Could not delete archived vault."
        }
    }

    func saveEditorText() {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        saveCurrentPayload()
    }

    func copySelectedNoteBodyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedNoteBody, forType: .string)
        copiedPasteboardChangeCount = NSPasteboard.general.changeCount
        editorStatusMessage = "Copied."
    }

    func reportEditorError(_ message: String) {
        editorStatusMessage = message
    }

    func setAutoSaveEnabled(_ isEnabled: Bool) {
        isAutoSaveEnabled = isEnabled

        if isEnabled {
            scheduleAutoSave()
        } else {
            autoSaveTask?.cancel()
            autoSaveTask = nil
        }
    }

    /// Called before termination so a failed save can cancel quitting.
    func prepareToQuit() -> Bool {
        endActiveTextInputSessions()
        if isLocked {
            return pendingRecovery == nil
        }
        return !hasUnsavedChanges || saveCurrentPayload()
    }

    @discardableResult
    private func saveCurrentPayload() -> Bool {
        autoSaveTask?.cancel()
        autoSaveTask = nil

        guard let derivedKey else {
            editorStatusMessage = "Save failed."
            return false
        }

        editorStatusMessage = "Saving..."

        do {
            try vaultService.savePayload(currentPayload(), using: derivedKey)
            hasUnsavedChanges = false
            pendingRecovery = nil
            editorStatusMessage = "Saved."
            return true
        } catch VaultService.VaultServiceError.invalidVault {
            editorStatusMessage = "Save failed: vault is too large."
        } catch {
            editorStatusMessage = "Save failed."
        }
        return false
    }

    var selectedNoteBody: String {
        guard let selectedNoteIndex else {
            return ""
        }

        return notes[selectedNoteIndex].body
    }

    var selectedNoteRichContent: VaultRichContent? {
        guard let selectedNoteIndex else {
            return nil
        }

        return notes[selectedNoteIndex].richContent
    }

    func updateSelectedNoteBody(_ body: String) {
        guard let selectedNoteIndex else {
            return
        }

        notes[selectedNoteIndex].body = body
        if !notes[selectedNoteIndex].isTitleFinalized,
           let title = titleFromFirstFiveWords(in: body) {
            notes[selectedNoteIndex].title = title
            notes[selectedNoteIndex].isTitleFinalized = true
        }
        notes[selectedNoteIndex].updatedAt = Date()
        sortNotesByRecency()
        markPayloadChanged()
    }

    func updateSelectedNoteContent(body: String, richContent: VaultRichContent) {
        guard let selectedNoteIndex else {
            return
        }

        let previousContent = notes[selectedNoteIndex].richContent
        let isLegacyStorageCompaction = notes[selectedNoteIndex].body == body
            && previousContent.map { VaultRichTextDocument.isLegacyRTFD($0.rtfdData) } == true
            && !VaultRichTextDocument.isLegacyRTFD(richContent.rtfdData)
            && previousContent?.imageAttachmentIDs == richContent.imageAttachmentIDs
            && previousContent?.imageDisplayWidths == richContent.imageDisplayWidths
            && previousContent?.imageSources == richContent.imageSources

        notes[selectedNoteIndex].body = body
        notes[selectedNoteIndex].richContent = richContent
        if !notes[selectedNoteIndex].isTitleFinalized,
           let title = titleFromFirstFiveWords(in: body) {
            notes[selectedNoteIndex].title = title
            notes[selectedNoteIndex].isTitleFinalized = true
        }
        if !isLegacyStorageCompaction {
            notes[selectedNoteIndex].updatedAt = Date()
            sortNotesByRecency()
        }
        markPayloadChanged()
    }

    func selectNote(id: String) {
        guard id != selectedNoteID,
              notes.contains(where: { $0.id == id })
        else {
            return
        }

        selectedNoteID = id
        markPayloadChanged()
    }

    func selectPreviousNote() {
        guard let selectedNoteIndex,
              !notes.isEmpty
        else {
            return
        }

        let previousIndex = max(selectedNoteIndex - 1, 0)
        guard previousIndex != selectedNoteIndex else {
            return
        }

        selectedNoteID = notes[previousIndex].id
        markPayloadChanged()
    }

    func selectNextNote() {
        guard let selectedNoteIndex,
              !notes.isEmpty
        else {
            return
        }

        let nextIndex = min(selectedNoteIndex + 1, notes.count - 1)
        guard nextIndex != selectedNoteIndex else {
            return
        }

        selectedNoteID = notes[nextIndex].id
        markPayloadChanged()
    }

    func createNote() {
        guard !isLocked else { return }
        guard notes.count < VaultResourcePolicy.maximumNoteCount else {
            editorStatusMessage = "Note limit reached."
            return
        }
        let now = Date()
        let note = VaultNote(
            id: UUID().uuidString,
            title: "Untitled",
            body: "",
            createdAt: now,
            updatedAt: now,
            isTitleFinalized: false
        )

        notes.append(note)
        sortNotesByRecency()
        selectedNoteID = note.id
        markPayloadChanged()
    }

    func renameNote(id: String, title: String) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[noteIndex].title = trimmedTitle.isEmpty ? "Untitled" : String(trimmedTitle.prefix(40))
        notes[noteIndex].isTitleFinalized = true
        notes[noteIndex].updatedAt = Date()
        sortNotesByRecency()
        hasUnsavedChanges = true
        saveCurrentPayload()
    }

    func deleteNote(id: String) {
        guard let noteIndex = notes.firstIndex(where: { $0.id == id }) else {
            return
        }

        notes.remove(at: noteIndex)

        if notes.isEmpty {
            createNote()
        } else if selectedNoteID == id {
            let nextIndex = min(noteIndex, notes.count - 1)
            selectedNoteID = notes[nextIndex].id
        }

        hasUnsavedChanges = true
        saveCurrentPayload()
    }

    private func markPayloadChanged() {
        hasUnsavedChanges = true
        editorStatusMessage = "Unsaved."
        scheduleAutoSave()
    }

    private func scheduleAutoSave() {
        guard isAutoSaveEnabled, hasUnsavedChanges else {
            return
        }

        autoSaveTask?.cancel()
        let delay = autoSaveDelayNanoseconds
        autoSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }

            self?.saveCurrentPayload()
        }
    }

    private func prepareVaultFile() {
        do {
            try vaultService.ensureVaultDirectoryExists()
            _ = try vaultService.loadVaultFile()
        } catch {
            // Keep the app runnable. Future phases can surface safe vault errors.
        }

        refreshVaultStatus()
    }

    private func clearSensitivePasteboardIfUnchanged() {
        guard let copiedPasteboardChangeCount else {
            return
        }

        if NSPasteboard.general.changeCount == copiedPasteboardChangeCount {
            NSPasteboard.general.clearContents()
        }

        self.copiedPasteboardChangeCount = nil
    }

    private func refreshVaultStatus() {
        vaultDirectoryExists = vaultService.vaultDirectoryExists()
        vaultFileExists = vaultService.vaultFileExists()
        vaultNeedsCreation = vaultService.vaultNeedsCreation()
        archivedVaults = (try? vaultService.archivedVaults()) ?? []
    }

    private var selectedNoteIndex: Int? {
        guard let selectedNoteID else {
            return nil
        }

        return notes.firstIndex(where: { $0.id == selectedNoteID })
    }

    private func loadPayloadIntoMemory(_ payload: VaultPayload) {
        let loadedNotes = payload.notes.isEmpty
            ? VaultPayload.singleEditorNote(body: "").notes
            : payload.notes

        notes = loadedNotes
        sortNotesByRecency()

        if let selectedNoteID = payload.selectedNoteID,
           loadedNotes.contains(where: { $0.id == selectedNoteID }) {
            self.selectedNoteID = selectedNoteID
        } else {
            selectedNoteID = notes.first?.id
        }
    }

    private func sortNotesByRecency() {
        notes.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    private func currentPayload() -> VaultPayload {
        VaultPayload(
            formatVersion: 2,
            notes: notes,
            selectedNoteID: selectedNoteID
        )
    }

    private func titleFromFirstFiveWords(in body: String) -> String? {
        let words = body.split { $0.isWhitespace || $0.isNewline }
        guard words.count >= 5 else {
            return nil
        }

        return String(words.prefix(5).joined(separator: " ").prefix(40))
    }

    private func authenticationErrorMessage(for error: Error) -> String {
        if vaultNeedsCreation {
            return "Could not create vault."
        }

        guard let vaultError = error as? VaultService.VaultServiceError else {
            return "Could not unlock vault. Check the password or vault file integrity."
        }

        switch vaultError {
        case .missingVault:
            return "Vault file is missing."
        case .invalidVault:
            return "Vault file is corrupted or unsupported."
        case .unlockFailed:
            return "Could not unlock vault. Check the password or vault file integrity."
        case .invalidKeyDerivationMetadata:
            return "Vault key metadata is corrupted or unsupported."
        case .missingDerivedKey:
            return "Could not unlock vault."
        case .archivedVaultNotFound:
            return "Archived vault is missing."
        }
    }

    private func isRecoverableCorruptedVaultError(_ error: Error) -> Bool {
        guard let vaultError = error as? VaultService.VaultServiceError else {
            return false
        }

        switch vaultError {
        case .invalidVault, .invalidKeyDerivationMetadata:
            return true
        case .missingVault, .unlockFailed, .missingDerivedKey, .archivedVaultNotFound:
            return false
        }
    }

    private func runDebugSelfChecks() {
        #if DEBUG
        do {
            try CryptoService.runSelfCheck()
            try KeyDerivationService.runSelfCheck()
            try vaultService.validateVaultFileForDebug()
        } catch {
            assertionFailure("Security self-check failed")
        }
        #endif
    }
}
