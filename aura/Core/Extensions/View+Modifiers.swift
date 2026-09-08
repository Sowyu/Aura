import SwiftUI

extension View {
    func withTheme() -> some View {
        self.modifier(ThemeProvider())
    }
}
