import SwiftUI

enum ClientTheme {
    static let backgroundTop = Color(red: 0.07, green: 0.09, blue: 0.12)
    static let backgroundBottom = Color(red: 0.03, green: 0.04, blue: 0.06)
    static let surface = Color(red: 0.10, green: 0.12, blue: 0.16)
    static let surfaceRaised = Color(red: 0.14, green: 0.17, blue: 0.22)
    static let surfaceMuted = Color(red: 0.18, green: 0.22, blue: 0.27)
    static let border = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.70)
    static let textMuted = Color.white.opacity(0.50)
    static let accent = Color(red: 0.23, green: 0.80, blue: 0.62)
    static let accentSecondary = Color(red: 0.31, green: 0.58, blue: 0.96)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.24)
    static let danger = Color(red: 0.94, green: 0.36, blue: 0.36)

    static let background = LinearGradient(
        colors: [backgroundTop, backgroundBottom],
        startPoint: .top,
        endPoint: .bottom
    )
}
