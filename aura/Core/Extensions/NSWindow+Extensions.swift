import AppKit
import Foundation

extension NSWindow {
    private static var previousFrameAssociationKey: UInt8 = 0

    /// Stores the current frame as the previous frame before maximizing.
    /// Kept per-window (associated object) — a shared persisted value would make
    /// one window restore to another window's frame.
    private var previousFrame: NSRect? {
        get {
            (objc_getAssociatedObject(self, &Self.previousFrameAssociationKey) as? NSValue)?.rectValue
        }
        set {
            objc_setAssociatedObject(
                self,
                &Self.previousFrameAssociationKey,
                newValue.map { NSValue(rect: $0) },
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Toggles the window between maximized (filling the visible screen) and restored states.
    /// Uses smooth animations and respects the menu bar and dock.
    /// Remembers the previous frame before maximizing and restores to that exact size/position.
    func toggleMaximized() {
        // Get the screen's visible frame (excludes menu bar and dock)
        guard let screen = self.screen else { return }
        let screenFrame = screen.visibleFrame

        // Check if window is already maximized (with some tolerance for small differences)
        let currentFrame = self.frame
        let tolerance: CGFloat = 10
        let isMaximized = abs(currentFrame.size.width - screenFrame.size.width) < tolerance &&
            abs(currentFrame.size.height - screenFrame.size.height) < tolerance &&
            abs(currentFrame.origin.x - screenFrame.origin.x) < tolerance &&
            abs(currentFrame.origin.y - screenFrame.origin.y) < tolerance

        if isMaximized {
            // If already maximized, restore to the previous frame if available
            if let storedFrame = previousFrame {
                self.setFrame(storedFrame, display: true, animate: !AnimationSettings.reduceMotion)
                // Clear the stored frame since we're restoring
                previousFrame = nil
            } else {
                // Fallback to default size if no previous frame is stored
                let restoredWidth: CGFloat = 1440
                let restoredHeight: CGFloat = 900
                let newFrame = NSRect(
                    x: screenFrame.midX - restoredWidth / 2,
                    y: screenFrame.midY - restoredHeight / 2,
                    width: restoredWidth,
                    height: restoredHeight
                )
                self.setFrame(newFrame, display: true, animate: !AnimationSettings.reduceMotion)
            }
        } else {
            // Store the current frame before maximizing
            previousFrame = currentFrame
            // Maximize to fill the visible screen area
            self.setFrame(screenFrame, display: true, animate: !AnimationSettings.reduceMotion)
        }
    }

    func performTitlebarDoubleClick() {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": performMiniaturize(nil)
        case "Fill": toggleMaximized()
        case "None": break
        default: performZoom(nil)
        }
    }
}
