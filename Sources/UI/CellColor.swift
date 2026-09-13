import SwiftUI
import UIKit

// MARK: - SwiftUI colour helpers

extension Color {
    init(argb: UInt32) {
        let a = 1.0 // Spreadsheet background fills are opaque.
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// Perceived brightness 0…1 (used to pick readable text colour over fills).
    var luminance: Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
    }
}
