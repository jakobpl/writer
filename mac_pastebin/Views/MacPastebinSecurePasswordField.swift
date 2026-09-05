import AppKit
import SwiftUI

/// AppKit owns secure text input on macOS. Keeping the first-responder handoff
/// here avoids SwiftUI focus races when the unlock screen is first presented.
struct MacPastebinSecurePasswordField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let accessibilityLabel: String
    let requestsInitialFocus: Bool
    let resetGeneration: UInt64
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SecurePasswordContainer {
        let container = SecurePasswordContainer()
        let field = container.textField
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit(_:))
        field.placeholderString = placeholder
        field.setAccessibilityLabel(accessibilityLabel)
        return container
    }

    func updateNSView(_ container: SecurePasswordContainer, context: Context) {
        context.coordinator.parent = self

        let field = container.textField
        context.coordinator.performRepresentableUpdate {
            if context.coordinator.consumeResetGeneration(resetGeneration) {
                container.setTextPreservingFocus("")
            } else if field.stringValue != text {
                container.setTextPreservingFocus(text)
            }
            field.placeholderString = placeholder
            field.setAccessibilityLabel(accessibilityLabel)
            container.requestsInitialFocus = requestsInitialFocus
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacPastebinSecurePasswordField
        private var lastResetGeneration: UInt64
        private var isPerformingRepresentableUpdate = false

        init(parent: MacPastebinSecurePasswordField) {
            self.parent = parent
            lastResetGeneration = parent.resetGeneration
        }

        func consumeResetGeneration(_ generation: UInt64) -> Bool {
            guard generation != lastResetGeneration else {
                return false
            }
            lastResetGeneration = generation
            return true
        }

        func performRepresentableUpdate(_ update: () -> Void) {
            isPerformingRepresentableUpdate = true
            defer { isPerformingRepresentableUpdate = false }
            update()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard !isPerformingRepresentableUpdate else { return }
            guard let field = notification.object as? NSSecureTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? ReactivatingSecureTextField else { return }
            field.secureCurrentEditor()
        }

        @objc func submit(_ sender: NSSecureTextField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}

final class SecurePasswordContainer: NSView {
    let textField = ReactivatingSecureTextField()

    var requestsInitialFocus = false {
        didSet {
            guard requestsInitialFocus != oldValue else { return }
            if !requestsInitialFocus {
                hasCompletedInitialFocusRequest = false
            }
            requestInitialFocusIfNeeded()
        }
    }

    private var focusRequestIsPending = false
    private var hasCompletedInitialFocusRequest = false
    private var shouldRestoreFocusWhenApplicationActivates = false
    private var focusRestoreIsPending = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 20, weight: .regular)
        textField.textColor = NSColor.labelColor.withAlphaComponent(0.70)

        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.heightAnchor.constraint(equalToConstant: 28)
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive(_:)),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestInitialFocusIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        _ = focusPasswordField(in: window)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func setTextPreservingFocus(_ text: String) {
        textField.secureCurrentEditor()
        textField.stringValue = text
        if let editor = textField.currentEditor(), editor.string != text {
            editor.string = text
        }
    }

    @discardableResult
    func focusPasswordField(in window: NSWindow) -> Bool {
        if let staleTextView = window.firstResponder as? NSTextView {
            staleTextView.inputContext?.discardMarkedText()
            staleTextView.unmarkText()
        }
        if window.firstResponder !== textField,
           window.firstResponder !== textField.currentEditor() {
            window.makeFirstResponder(nil)
        }

        textField.prepareSecureFieldEditor(in: window)
        let focused = window.makeFirstResponder(textField)
        textField.secureCurrentEditor()
        return focused
    }

    private func requestInitialFocusIfNeeded() {
        guard requestsInitialFocus,
              !focusRequestIsPending,
              !hasCompletedInitialFocusRequest,
              window != nil
        else { return }
        focusRequestIsPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusRequestIsPending = false
            guard
                self.requestsInitialFocus,
                let window = self.window,
                NSApp.isActive,
                window.isKeyWindow
            else { return }

            let firstResponder = window.firstResponder
            if firstResponder === self.textField || firstResponder === self.textField.currentEditor() {
                self.hasCompletedInitialFocusRequest = true
                return
            }

            // Preserve an explicit choice of the other secure field, but do not
            // mistake the outgoing note editor for a password field.
            if self.isAnotherSecureFieldResponder(firstResponder, in: window) {
                self.hasCompletedInitialFocusRequest = true
                return
            }

            if self.focusPasswordField(in: window) {
                self.hasCompletedInitialFocusRequest = true
            }
        }
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        guard let window else { return }
        let firstResponder = window.firstResponder
        shouldRestoreFocusWhenApplicationActivates = firstResponder === textField
            || firstResponder === textField.currentEditor()
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        restoreFocusAfterApplicationActivationIfNeeded()
        requestInitialFocusIfNeeded()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        restoreFocusAfterApplicationActivationIfNeeded()
        requestInitialFocusIfNeeded()
    }

    private func restoreFocusAfterApplicationActivationIfNeeded() {
        guard shouldRestoreFocusWhenApplicationActivates,
              !focusRestoreIsPending,
              window != nil
        else { return }
        focusRestoreIsPending = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusRestoreIsPending = false
            guard self.shouldRestoreFocusWhenApplicationActivates,
                  let window = self.window,
                  NSApp.isActive,
                  window.isKeyWindow
            else { return }

            let firstResponder = window.firstResponder
            if firstResponder === self.textField || firstResponder === self.textField.currentEditor() {
                self.shouldRestoreFocusWhenApplicationActivates = false
                return
            }

            if self.isAnotherSecureFieldResponder(firstResponder, in: window) {
                self.shouldRestoreFocusWhenApplicationActivates = false
                return
            }

            if self.focusPasswordField(in: window) {
                self.shouldRestoreFocusWhenApplicationActivates = false
            }
        }
    }

    private func isAnotherSecureFieldResponder(
        _ responder: NSResponder?,
        in window: NSWindow
    ) -> Bool {
        guard let responder, let contentView = window.contentView else {
            return false
        }

        return secureTextFields(in: contentView).contains { field in
            field !== textField
                && (responder === field || responder === field.currentEditor())
        }
    }

    private func secureTextFields(in view: NSView) -> [ReactivatingSecureTextField] {
        var fields = view.subviews.compactMap { $0 as? ReactivatingSecureTextField }
        for subview in view.subviews {
            fields.append(contentsOf: secureTextFields(in: subview))
        }
        return fields
    }
}

/// Receives the click that reactivates the app, instead of requiring a second
/// click before AppKit starts secure text editing again.
final class ReactivatingSecureTextField: NSSecureTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disableTextAssistance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        disableTextAssistance()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        if let window {
            prepareSecureFieldEditor(in: window)
        }
        let becameFirstResponder = super.becomeFirstResponder()
        secureCurrentEditor()
        return becameFirstResponder
    }

    func prepareSecureFieldEditor(in window: NSWindow) {
        guard let editor = window.fieldEditor(true, for: self) as? NSTextView else {
            return
        }
        Self.disableTextAssistance(in: editor)
    }

    func secureCurrentEditor() {
        guard let editor = currentEditor() as? NSTextView else { return }
        Self.disableTextAssistance(in: editor)
    }

    static func disableTextAssistance(in editor: NSTextView) {
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.enabledTextCheckingTypes = 0
        editor.writingToolsBehavior = .none
        editor.allowsCharacterPickerTouchBarItem = false
    }

    private func disableTextAssistance() {
        isAutomaticTextCompletionEnabled = false
        allowsCharacterPickerTouchBarItem = false
        allowsWritingTools = false
        allowsWritingToolsAffordance = false
    }
}
