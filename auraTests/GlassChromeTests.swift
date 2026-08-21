import AppKit
@testable import Aura
import Testing

/// The two numbers behind Liquid Glass: how far the tint goes, and which AppKit
/// material each step of the blur slider lands on.
struct GlassChromeTests {
    @Test func tintOpacityNeverFallsBelowTheFloor() {
        // 0 is what older builds could store, and it renders as no chrome at all.
        #expect(AuraGlass.clampedOpacity(0) == AuraGlass.minOpacity)
        #expect(AuraGlass.clampedOpacity(-1) == AuraGlass.minOpacity)
        #expect(AuraGlass.clampedOpacity(0.42) == 0.42)
        #expect(AuraGlass.clampedOpacity(3) == 1)
    }

    @Test func everyBlurStepPicksItsOwnMaterial() {
        #expect(AuraGlass.material(forBlur: 0) == nil)
        #expect(AuraGlass.material(forBlur: 0.25) == .hudWindow)
        #expect(AuraGlass.material(forBlur: 0.5) == .titlebar)
        #expect(AuraGlass.material(forBlur: 0.75) == .sidebar)
        #expect(AuraGlass.material(forBlur: 1) == .fullScreenUI)
        // Out of range values land on the nearest end rather than crashing the switch.
        #expect(AuraGlass.material(forBlur: -0.5) == nil)
        #expect(AuraGlass.material(forBlur: 9) == .fullScreenUI)
    }

    @MainActor
    @Test func turningGlassOffMakesTheWindowOpaqueAgain() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        AuraGlass.applyWindowTransparency(to: window, enabled: true)
        #expect(window.isOpaque == false)
        #expect(window.backgroundColor == .clear)
        #expect(window.hasShadow)

        AuraGlass.applyWindowTransparency(to: window, enabled: false)
        #expect(window.isOpaque)
        #expect(window.backgroundColor == .windowBackgroundColor)
        #expect(window.hasShadow)
    }
}
