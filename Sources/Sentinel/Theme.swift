import AppKit
import SwiftUI

// Single source of truth for Sentinel's look. Values come from the "Sentinel Redesign" canvas
// (dark + light). Every view reads colors from here instead of hard-coding them.

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// A color that switches with the system appearance.
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private func ns(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Theme {
    // Brand
    static let accent = Color(hex: 0x3F6BFF)
    static let accentDeep = Color(hex: 0x2F55D8)
    static let violet = Color(hex: 0x8B5CF6)
    static let slider = Color(hex: 0x6A5CF6)

    // Surfaces
    static let win = Color.dynamic(dark: ns(0x171B29), light: ns(0xF4F6FB))
    static let edge = Color.dynamic(dark: ns(0x788CFF, 0.22), light: ns(0x283C8C, 0.16))
    static let card = Color.dynamic(dark: ns(0xFFFFFF, 0.065), light: ns(0x1E3278, 0.055))
    static let cardHover = Color.dynamic(dark: ns(0xFFFFFF, 0.11), light: ns(0x1E3278, 0.10))
    static let tabbar = Color.dynamic(dark: ns(0xFFFFFF, 0.05), light: ns(0x1E3278, 0.05))
    static let track = Color.dynamic(dark: ns(0xFFFFFF, 0.12), light: ns(0x1E3278, 0.12))

    // Text
    static let t1 = Color.dynamic(dark: ns(0xFFFFFF), light: ns(0x14182B))
    static let t2 = Color.dynamic(dark: ns(0xA9AFC4), light: ns(0x575D74))
    static let link = Color.dynamic(dark: ns(0x8FA6FF), light: ns(0x2F55D8))

    // Status
    static let success = Color.dynamic(dark: ns(0x3FB95F), light: ns(0x248A3D))
    static let warning = Color.dynamic(dark: ns(0xFFAE4D), light: ns(0xC2620A))
    static let danger = Color.dynamic(dark: ns(0xFF6B63), light: ns(0xC62F28))

    // Gradients
    static var brand: LinearGradient {
        LinearGradient(colors: [accent, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var ring: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x5B86FF), Color(hex: 0x9B6CFF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var iconTile: LinearGradient {
        LinearGradient(colors: [Color(hex: 0x1C2650), Color(hex: 0x0C1226)], startPoint: .top, endPoint: .bottom)
    }

    // Radii, spacing
    static let radiusCard: CGFloat = 12
    static let radiusPanel: CGFloat = 14
    static let gutter: CGFloat = 16
}

/// Colored tile used behind tool and action icons.
enum TileStyle {
    case clean, trash, remove, startup, bigFiles, duplicates, lens, maintenance, history

    private var pair: (UInt32, UInt32) {
        switch self {
        case .clean: (0x6C7BFF, 0x2F55D8)
        case .trash: (0xFF6B63, 0xE0453D)
        case .remove: (0xFFAE4D, 0xF08A24)
        case .startup: (0x5EDB7A, 0x34B955)
        case .bigFiles: (0x6FD8E6, 0x2FB5C9)
        case .duplicates: (0xFF7A93, 0xE0456B)
        case .lens: (0x7D8BFF, 0x5C4FE0)
        case .maintenance: (0xFFD25E, 0xE8A317)
        case .history: (0xA3ABC2, 0x646D86)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: pair.0), Color(hex: pair.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var solid: Color { Color(hex: pair.1) }
}

// MARK: - Logo

/// The shield outline from the Sentinel mark (24 x 24 design grid).
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(12, 2.75))
        path.addLine(to: p(19.25, 5.6))
        path.addLine(to: p(19.25, 11.5))
        path.addCurve(to: p(12, 21.25), control1: p(19.25, 16), control2: p(16.25, 19.4))
        path.addCurve(to: p(4.75, 11.5), control1: p(7.75, 19.4), control2: p(4.75, 16))
        path.addLine(to: p(4.75, 5.6))
        path.closeSubpath()
        return path
    }
}

/// The gauge arc and needle inside the shield.
struct GaugeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        // arc from (8.1, 14.4) over the top to (15.9, 14.4), drawn as points so the direction is unambiguous
        let steps = 24
        for i in 0...steps {
            let a = Double.pi + Double.pi * Double(i) / Double(steps)
            let pt = p(12 + 3.9 * CGFloat(cos(a)), 14.4 + 3.9 * CGFloat(sin(a)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.move(to: p(12, 14.4))
        path.addLine(to: p(14.6, 11.2))
        return path
    }
}

struct SentinelMark: View {
    var size: CGFloat = 20
    var body: some View {
        ZStack {
            ShieldShape().fill(LinearGradient(colors: [Color(hex: 0x4F7BFF), Theme.violet],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
            GaugeShape().stroke(.white, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
            Circle().fill(.white).frame(width: size * 0.1, height: size * 0.1)
                .position(x: size * 0.5, y: size * 0.6)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The dark rounded tile that holds the mark (header and About screen).
struct LogoTile: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Theme.iconTile)
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).strokeBorder(Color(hex: 0x2A4EBC), lineWidth: 1)
            SentinelMark(size: size * 0.66)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Controls

struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.track))
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                        .opacity(configuration.isOn ? 1 : 0).scaleEffect(configuration.isOn ? 1 : 0.5)
                }
                .frame(width: 18, height: 18)
                configuration.label.foregroundStyle(Theme.t1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.25), value: configuration.isOn)
        .accessibilityAddTraits(.isButton)
    }
}
