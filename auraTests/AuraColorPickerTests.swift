import Foundation
@testable import Aura
import Testing

/// The hex field feeds `Color(hex:)`, whose `Scanner` stops at the first character it
/// cannot read and reports the rest as zero. "#GG00ZZ" therefore used to be accepted and
/// paint the space black, so the field validates the digits itself.
@Suite("Colour picker hex field")
struct AuraColorPickerTests {
    @Test("The three lengths Color(hex:) understands are accepted")
    func acceptedLengths() {
        #expect(AuraColorPicker.normalizedHex("#f0a") == "#F0A")
        #expect(AuraColorPicker.normalizedHex("4dabf7") == "#4DABF7")
        #expect(AuraColorPicker.normalizedHex("#80FF6B6B") == "#80FF6B6B")
    }

    @Test("Surrounding whitespace and a missing hash are tolerated")
    func tolerance() {
        #expect(AuraColorPicker.normalizedHex("  ff6b6b  ") == "#FF6B6B")
    }

    @Test("Anything that is not a hex digit is rejected")
    func rejectsNonHexDigits() {
        #expect(AuraColorPicker.normalizedHex("#GG00ZZ") == nil)
        #expect(AuraColorPicker.normalizedHex("#12 34 56") == nil)
        #expect(AuraColorPicker.normalizedHex("rebeccapurple") == nil)
    }

    @Test("Lengths Color(hex:) would fall back to grey on are rejected")
    func rejectsWrongLengths() {
        #expect(AuraColorPicker.normalizedHex("") == nil)
        #expect(AuraColorPicker.normalizedHex("#FF") == nil)
        #expect(AuraColorPicker.normalizedHex("#FF6B6B6") == nil)
    }

    /// Every swatch in the row has to survive the same check, or picking one and then
    /// pressing Return in the field would reject it.
    @Test("Every preset passes its own validator")
    func presetsAreValid() {
        for preset in SpaceIconCatalog.palette {
            #expect(AuraColorPicker.normalizedHex(preset) == preset.uppercased())
        }
    }
}
