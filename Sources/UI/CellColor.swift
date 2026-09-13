import SwiftUI

// MARK: - SwiftUI colour helpers

extension Color {
    init(argb: UInt32) {
        let a = 1.0 // Spreadsheet background fills are opaque.
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

}
