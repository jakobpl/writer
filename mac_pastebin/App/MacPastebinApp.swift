import AppKit
import SwiftUI

@main
struct MacPastebinApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(MacPastebinAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("mac_pastebin", id: "main") {
            AppRootView()
                .environmentObject(appState)
                .onAppear { appDelegate.appState = appState }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    appState.lock()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
                    if !NSApplication.shared.isActive {
                        appState.lock()
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") {
                    appState.createNote()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(appState.isLocked)
            }
        }
    }
}

@MainActor
final class MacPastebinAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState, !appState.prepareToQuit() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Changes have not been saved"
        alert.informativeText = "Quitting would lose unsaved changes. Keep the app open, unlock if needed, and save your notes before quitting."
        alert.addButton(withTitle: "Keep Open")
        alert.runModal()
        return .terminateCancel
    }
}
