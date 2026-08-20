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

        override var mouseDownCanMoveWindow: Bool { false }

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
            window.makeFirstResponder(self)
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
        if let textColor {
            textField.textColor = NSColor(textColor)
        }
        return textField
    }

    func updateNSView(_ nsView: CustomTextField, context: Context) {
        context.coordinator.parent = self
        let focused = nsView.currentEditor() != nil
        let wanted = (displayText == nil || focused) ? text : (displayText ?? "")
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
        if let isEditing, isEditing != focused {
            // Outside a SwiftUI update pass: becoming first responder writes state.
            DispatchQueue.main.async {
                guard let window = nsView.window, isEditing != (nsView.currentEditor() != nil) else { return }
                window.makeFirstResponder(isEditing ? nsView : nil)
            }
        }
        nsView.cursorColor = NSColor(cursorColor)
        nsView.placeholderString = placeholder
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
