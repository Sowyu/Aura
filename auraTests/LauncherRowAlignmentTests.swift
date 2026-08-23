import CoreGraphics
import Foundation
@testable import Aura
import Testing

/// Suggestion rows have to start their titles on the same column as the text of the
/// field they hang under. They used to sit about 10pt to the left of it, because both
/// columns were built from separate literals.
@Suite("Launcher row alignment")
struct LauncherRowAlignmentTests {
    /// Where a row puts its title, measured from the panel's leading edge.
    private func titleColumn(panelPadding: CGFloat, iconWidth: CGFloat, leadingInset: CGFloat) -> CGFloat {
        panelPadding + leadingInset + iconWidth + LauncherRowMetrics.spacing
    }

    @Test("The floating launcher's rows line up with its field")
    func launcherPanel() {
        let panelPadding: CGFloat = 6
        let inset = LauncherRowMetrics.leadingInset(
            textInset: LauncherField.textInset,
            panelPadding: panelPadding,
            iconWidth: LauncherField.iconWidth
        )

        #expect(
            titleColumn(panelPadding: panelPadding, iconWidth: LauncherField.iconWidth, leadingInset: inset)
                == LauncherField.textInset
        )
    }

    @Test("The address bar's rows line up with its own, narrower field")
    func urlBarPanel() {
        let panelPadding: CGFloat = 8
        let iconWidth: CGFloat = 16
        let inset = LauncherRowMetrics.leadingInset(
            textInset: URLBarField.textInset,
            panelPadding: panelPadding,
            iconWidth: iconWidth
        )

        #expect(
            titleColumn(panelPadding: panelPadding, iconWidth: iconWidth, leadingInset: inset)
                == URLBarField.textInset
        )
    }

    /// The two fields differ, so a shared constant would have to be wrong for one of them.
    @Test("The two fields really do have different text columns")
    func theInsetsDiffer() {
        #expect(LauncherField.textInset == 52)
        #expect(URLBarField.textInset == 32)
    }

    /// A panel deeper than the text column cannot produce a negative pad.
    @Test("A deep panel padding clamps at zero")
    func clampsAtZero() {
        let inset = LauncherRowMetrics.leadingInset(textInset: 20, panelPadding: 40, iconWidth: 16)
        #expect(inset == 0)
    }
}
