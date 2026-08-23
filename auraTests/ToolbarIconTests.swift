import AppKit
import Foundation
@testable import Aura
import Testing

@Suite("Toolbar icons")
struct ToolbarIconTests {
    /// The five navigation marks are Firefox's own toolbar SVGs. They have to arrive as
    /// template images at their native 16pt, or the chrome row draws them flat black and
    /// at whatever size the file happens to carry.
    @MainActor
    @Test func everyIconLoadsAsA16ptTemplateImage() {
        for icon in ToolbarIcon.allCases {
            guard let image = ToolbarIcon.image(icon) else {
                Issue.record("No bundled image for \(icon.resourceName)")
                continue
            }
            #expect(image.isTemplate, "\(icon.resourceName) is not a template image")
            #expect(image.size == NSSize(width: 16, height: 16), "\(icon.resourceName) is \(image.size)")
            #expect(!image.representations.isEmpty, "\(icon.resourceName) has no representations")
        }
    }

    @MainActor
    @Test func repeatedLoadsHandBackTheSameImage() {
        #expect(ToolbarIcon.image(.back) === ToolbarIcon.image(.back))
    }

    @Test func resourceNamesCarryTheFlattenedPrefix() {
        #expect(ToolbarIcon.back.resourceName == "toolbar-back")
        #expect(ToolbarIcon.allCases.count == 5)
    }
}
