import SwiftUI

/// Credit line in the footer. Change these three values to rebrand the app.
enum Branding {
    static let credit = "Created by Damon Flores —"
    static let linkLabel = "damonflores.com"
    static let linkURL = URL(string: "https://damonflores.com")!
}

enum Theme {
    static let background = Color(red: 0.110, green: 0.110, blue: 0.122)
    static let panel = Color(red: 0.133, green: 0.133, blue: 0.149)
    static let stroke = Color.white.opacity(0.20)
    static let accent = Color(red: 0.373, green: 0.612, blue: 0.996)
    static let accentDim = Color(red: 0.165, green: 0.243, blue: 0.384)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.32)
    static let success = Color(red: 0.36, green: 0.82, blue: 0.52)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.30)
}

struct PillStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }
    var kind: Kind
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 15 : 16, weight: .semibold))
            .padding(.horizontal, compact ? 30 : 26)
            .padding(.vertical, compact ? 11 : 12)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(background))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return isEnabled ? .white : .white.opacity(0.35)
        case .secondary, .ghost: return isEnabled ? .white.opacity(0.85) : .white.opacity(0.22)
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return isEnabled ? Theme.accent : Theme.accentDim
        case .secondary: return isEnabled ? .white.opacity(0.09) : .white.opacity(0.03)
        case .ghost: return .clear
        }
    }
}
