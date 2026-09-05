import Foundation
import XCTest
@testable import mac_pastebin

@MainActor
final class AppStateTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
    }

    func testNotesAreOrderedByMostRecentActivity() throws {
        let service = makeService()
        let password = "a unique ordering test passphrase"
        let unlockResult = try service.createVault(password: password)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let olderNote = VaultNote(
            id: "older",
            title: "Older",
            body: "Old body",
            createdAt: baseDate,
            updatedAt: baseDate,
            isTitleFinalized: true
        )
        let newerNote = VaultNote(
            id: "newer",
            title: "Newer",
            body: "New body",
            createdAt: baseDate.addingTimeInterval(60),
            updatedAt: baseDate.addingTimeInterval(120),
            isTitleFinalized: true
        )
        try service.savePayload(
            VaultPayload(
                formatVersion: 2,
                notes: [olderNote, newerNote],
                selectedNoteID: olderNote.id
            ),
            using: unlockResult.key
        )

        let appState = AppState(vaultService: service)
        appState.createOrUnlockVault(password: password)

        XCTAssertEqual(appState.notes.map(\.id), [newerNote.id, olderNote.id])
        XCTAssertEqual(appState.selectedNoteID, olderNote.id)

        appState.createNote()
        let createdNoteID = try XCTUnwrap(appState.selectedNoteID)
        XCTAssertEqual(appState.notes.first?.id, createdNoteID)

        appState.selectNote(id: olderNote.id)
        appState.updateSelectedNoteBody("Edited old body")
        XCTAssertEqual(appState.notes.first?.id, olderNote.id)

        appState.selectNote(id: newerNote.id)
        appState.updateSelectedNoteContent(
            body: "Edited rich body",
            richContent: VaultRichContent(rtfdData: Data())
        )
        XCTAssertEqual(appState.notes.first?.id, newerNote.id)
    }

    func testFailedSaveLocksAndRecoversEditsWithoutAllowingQuitOrVaultReplacement() throws {
        let service = makeService()
        let password = "a unique recovery test passphrase"
        _ = try service.createVault(password: password)
        let state = AppState(vaultService: service)
        state.createOrUnlockVault(password: password)
        state.updateSelectedNoteBody("Edits that must survive a disk failure")

        let fileURL = try service.vaultFileURL
        let originalFile = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        XCTAssertFalse(state.prepareToQuit())
        state.lock()
        XCTAssertTrue(state.isLocked)
        XCTAssertTrue(state.notes.isEmpty)
        XCTAssertFalse(state.prepareToQuit())
        state.startNewVaultAfterForgettingPassword()
        XCTAssertTrue(try fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)

        try FileManager.default.removeItem(at: fileURL)
        try originalFile.write(to: fileURL)
        state.createOrUnlockVault(password: "wrong password")
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.prepareToQuit())
        state.createOrUnlockVault(password: password)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.selectedNoteBody, "Edits that must survive a disk failure")
        XCTAssertTrue(state.prepareToQuit())
        state.lock()
        XCTAssertTrue(state.prepareToQuit())
        XCTAssertEqual(try service.unlockVault(password: password).payload.selectedEditorText,
                       "Edits that must survive a disk failure")
    }

    func testQuitSavesWithAutoSaveDisabled() throws {
        let service = makeService()
        let password = "a unique quit test passphrase"
        let state = AppState(vaultService: service)
        state.createOrUnlockVault(password: password)
        XCTAssertFalse(state.isAutoSaveEnabled)
        state.updateSelectedNoteBody("Last edits before quitting")
        XCTAssertTrue(state.prepareToQuit())
        XCTAssertEqual(try service.unlockVault(password: password).payload.selectedEditorText,
                       "Last edits before quitting")
    }

    func testCreatingNoteWhileLockedDoesNothing() {
        let state = AppState(vaultService: makeService())
        state.createNote()
        XCTAssertTrue(state.notes.isEmpty)
        XCTAssertNil(state.selectedNoteID)
    }

    private func makeService() -> VaultService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac_pastebin-app-state-tests-\(UUID().uuidString)", isDirectory: true)
        temporaryDirectories.append(directory)
        return VaultService(
            applicationSupportDirectory: directory,
            newVaultIterationCount: 1
        )
    }
}
