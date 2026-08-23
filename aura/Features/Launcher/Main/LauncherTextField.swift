import SwiftUI

struct LauncherTextField: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    let onTab: () -> Void
    let onSubmit: () -> Void
    let onDelete: () -> Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    var cursorColor: Color
    var textColor: Color?
    var placeholder: String

    // URL-bar mode. `displayText` is shown while the field is not focused; focusing
    // swaps in `text`, selects it all, and reports the change through the callbacks.
    // `isEditing` drives focus from the outside (shortcut, dismiss, tab switch).
    var displayText: String?
    var isEditing: Bool?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onEscape: (() -> Void)?

    /// The window's shared field editor is transparent, so AppKit's default
    /// `mouseDownCanMoveWindow` would let a drag inside it move a hidden-titlebar window.
    final class FieldEditor: NSTextView {
        override var mouseDownCanMoveWindow: Bool { false }
    }

    final class Cell: NSTextFieldCell {
        private let editor: FieldEditor = {
            let editor = FieldEditor()
            editor.isFieldEditor = true
            return editor
        }()

        override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
    }

    class CustomTextField: NSTextField {
        var cursorColor: NSColor?
        /// Returns the string to edit; nil means plain text field behaviour.
        var beginEditing: (() -> String)?

        override class var cellClass: AnyClass? {
            get { Cell.self }
            set {}
        }

        /// AppKit hands first responder to the nearest text field whenever the current
        /// responder (a web view mid-navigation) goes away. That must not start a URL
        /// edit, so focus is only accepted after a click or an explicit `isEditing`.
        var allowsFocus = false
        override var acceptsFirstResponder: Bool { allowsFocus && super.acceptsFirstResponder }

        /// Focus asked for before the field was in a window, taken the moment it is.
        var pendingFocus = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard pendingFocus, let window else { return }
            pendingFocus = false
            allowsFocus = true
            window.makeFirstResponder(self)
        }
        override var mouseDownCanMoveWindow: Bool { false }

        /// Holds first responder here while the field is being edited, so switching to
        /// another app and back does not drop the edit. See `AuraWindow.swift`.
        private lazy var focusLock = FirstResponderLock(view: self)

        var wantsFocus = false {
            didSet {
                guard wantsFocus != oldValue else { return }
                if wantsFocus { focusLock.lock() } else { focusLock.unlock() }
            }
        }

        private func configureEditorIfNeeded() {
            guard let textView = currentEditor() as? NSTextView else { return }
            if let color = cursorColor {
                textView.insertionPointColor = color
            }
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: .greatestFiniteMagnitude,
                height: bounds.height
            )
            textView.textContainer?.lineBreakMode = .byClipping
            textView.textContainer?.maximumNumberOfLines = 1
        }

        override func becomeFirstResponder() -> Bool {
            if let beginEditing {
                stringValue = beginEditing()
            }
            let didBecome = super.becomeFirstResponder()
            if didBecome {
                configureEditorIfNeeded()
                // Browser convention: focusing the address field selects the whole URL.
                currentEditor()?.selectAll(nil)
            }
            return didBecome
        }

        override func textDidBeginEditing(_ notification: Notification) {
            super.textDidBeginEditing(notification)
            configureEditorIfNeeded()
        }

        /// Safari-style: a click on an unfocused field selects everything, a drag
        /// from the same spot selects a range. The field editor owns the drag, so
        /// the window never moves.
        /// First click focuses and selects all; subsequent clicks and drags go to the field
        /// editor, which selects ranges natively. No event pumping: a `nextEvent` loop here
        /// froze the app when a synthetic mouse-up (remote control) never matched.
        override func mouseDown(with event: NSEvent) {
            guard currentEditor() == nil, let window else {
                super.mouseDown(with: event)
                return
            }
            allowsFocus = true
            window.makeFirstResponder(self)
            // `NSTextFieldCell` installs the field editor with the click that focused the
            // field, and that drops the caret where the pointer is — undoing the
            // `selectAll` in `becomeFirstResponder`. Re-select once that has settled.
            DispatchQueue.main.async { [weak self] in
                guard let self, currentEditor() != nil else { return }
                // The button is still down: this is a drag, and the user is choosing a
                // range. Selecting all here threw that selection away mid-gesture.
                guard NSEvent.pressedMouseButtons == 0 else { return }
                currentEditor()?.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> CustomTextField {
        let textField = CustomTextField()
        textField.delegate = context.coordinator
        textField.font = font
        textField.bezelStyle = .roundedBezel
        textField.isBordered = false
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.placeholderString = placeholder
        textField.lineBreakMode = .byClipping
        textField.maximumNumberOfLines = 1
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        // The field draws no label of its own, and this one view is both the address bar
        // and the launcher, so the placeholder is the only thing that says which.
        textField.setAccessibilityLabel(placeholder.isEmpty ? "Search or enter address" : placeholder)
        if let textColor {
            textField.textColor = NSColor(textColor)
        }
        return textField
    }

    func updateNSView(_ nsView: CustomTextField, context: Context) {
        context.coordinator.parent = self
        let focused = nsView.currentEditor() != nil
        let wanted = (displayText == nil || focused) ? text : (displayText ?? "")
        // Launcher and home-page fields have no display mode; they take focus freely.
        if displayText == nil { nsView.allowsFocus = true }
        if nsView.stringValue != wanted {
            // Prevent the AppKit delegate callback from bouncing this write
            // straight back into SwiftUI during the same update pass.
            context.coordinator.isProgrammaticUpdate = true
            nsView.stringValue = wanted
            context.coordinator.isProgrammaticUpdate = false
        }
        nsView.beginEditing = displayText == nil ? nil : { [text = $text] in
            onBeginEditing?()
            return text.wrappedValue
        }
        if let isEditing { nsView.wantsFocus = isEditing }
        if let isEditing, isEditing != focused {
            // Outside a SwiftUI update pass: becoming first responder writes state.
            DispatchQueue.main.async {
                guard let window = nsView.window else {
                    // A home tab opened with a shortcut asks for focus in the pass that
                    // inserts its field, before the field is in a window. Keep the ask
                    // and honour it from `viewDidMoveToWindow`, or the 0.1 s pulse that
                    // carries it expires and the user has to click the field.
                    nsView.pendingFocus = isEditing
                    return
                }
                guard isEditing != (nsView.currentEditor() != nil) else { return }
                nsView.allowsFocus = isEditing
                window.makeFirstResponder(isEditing ? nsView : nil)
            }
        }
        nsView.cursorColor = NSColor(cursorColor)
        nsView.placeholderString = placeholder
        nsView.setAccessibilityLabel(placeholder.isEmpty ? "Search or enter address" : placeholder)
        if let textColor {
            nsView.textColor = NSColor(textColor)
        }
        if let textView = nsView.currentEditor() as? NSTextView {
            textView.insertionPointColor = nsView.cursorColor
            textView.isHorizontallyResizable = true
            textView.isVerticallyResizable = false
            textView.textContainerInset = .zero
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: .greatestFiniteMagnitude,
                height: nsView.bounds.height
            )
            textView.textContainer?.lineBreakMode = .byClipping
            textView.textContainer?.maximumNumberOfLines = 1
        }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: LauncherTextField
        var isProgrammaticUpdate = false

        init(_ parent: LauncherTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticUpdate else { return }
            if let textField = obj.object as? NSTextField, parent.text != textField.stringValue {
                parent.text = textField.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            (obj.object as? CustomTextField)?.allowsFocus = false
            parent.onEndEditing?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                parent.onTab()
                return true
            } else if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            } else if selector == #selector(NSResponder.deleteBackward(_:)) {
                return parent.onDelete()
            } else if selector == #selector(NSResponder.cancelOperation(_:)), let onEscape = parent.onEscape {
                onEscape()
                return true
            } else if selector == #selector(NSResponder.moveUp(_:)) || selector ==
                #selector(NSResponder.moveToBeginningOfParagraph(_:))
            {
                parent.onMoveUp()
                return true
            } else if selector == #selector(NSResponder.moveDown(_:)) || selector ==
                #selector(NSResponder.moveToEndOfParagraph(_:))
            {
                parent.onMoveDown()
                return true
            }

            return false
        }
    }
}
