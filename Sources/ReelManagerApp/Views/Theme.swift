import SwiftUI
import ReelCore

/// Shared look: brand colors, platform colors, cards, badges, empty states.
enum Theme {
    static let brand = LinearGradient(colors: [Color(red: 0.98, green: 0.36, blue: 0.42),
                                               Color(red: 0.62, green: 0.31, blue: 0.96)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accent = Color(red: 0.78, green: 0.33, blue: 0.85)
    static let corner: CGFloat = 12
}

extension Platform {
    var color: Color {
        switch self {
        case .instagram: return Color(red: 0.88, green: 0.19, blue: 0.47)
        case .facebook: return Color(red: 0.09, green: 0.47, blue: 0.95)
        case .tiktok: return Color(red: 0.0, green: 0.78, blue: 0.80)
        case .youtube: return Color(red: 0.93, green: 0.11, blue: 0.14)
        }
    }

    var gradient: LinearGradient {
        switch self {
        case .instagram:
            return LinearGradient(colors: [Color(red: 0.99, green: 0.69, blue: 0.27), Color(red: 0.88, green: 0.19, blue: 0.47),
                                           Color(red: 0.51, green: 0.23, blue: 0.71)],
                                  startPoint: .bottomLeading, endPoint: .topTrailing)
        case .tiktok:
            return LinearGradient(colors: [Color(red: 0.15, green: 0.96, blue: 0.93), Color.black, Color(red: 1, green: 0.17, blue: 0.33)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
    }

    /// Short letter mark used in the round platform badge.
    var mark: String {
        switch self {
        case .instagram: return "IG"
        case .facebook: return "f"
        case .tiktok: return "TT"
        case .youtube: return "▶"
        }
    }
}

/// Round platform badge (brand logos aren't bundled, so it's a colored mark).
struct PlatformBadge: View {
    let platform: Platform
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(platform.gradient)
            Text(platform.mark)
                .font(.system(size: size * (platform.mark.count > 1 ? 0.36 : 0.5), weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(platform.displayName)
    }
}

struct StatusDot: View {
    let status: AccountStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
    }
    var color: Color {
        switch status {
        case .connected: return .green
        case .pending: return .yellow
        case .error: return .red
        case .disconnected: return .gray
        }
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Color.primary.opacity(0.07)))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Big friendly placeholder for empty screens.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.brand.opacity(0.15)).frame(width: 84, height: 84)
                Image(systemName: icon).font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.brand)
            }
            Text(title).font(.title3.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(BrandButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Theme.brand))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.bold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

/// Label + selectable value + copy button, for redirect URIs and such.
struct CopyField: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(value).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(2).truncationMode(.middle)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
    }
}

func compactNumber(_ n: Int?) -> String {
    guard let n else { return "–" }
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 10_000...: return String(format: "%.0fK", Double(n) / 1_000)
    case 1_000...: return String(format: "%.1fK", Double(n) / 1_000)
    default: return "\(n)"
    }
}
