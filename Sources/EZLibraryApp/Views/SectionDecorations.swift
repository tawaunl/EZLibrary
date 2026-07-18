import SwiftUI

struct SectionHeaderCard: View {
    let title: String
    let description: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .font(.system(size: 30, weight: .semibold, design: .default))
            }

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.14), Color(nsColor: .windowBackgroundColor)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
        .glowCardStyle()
    }
}

struct GlowCardStyle: ViewModifier {
    var radius: CGFloat = 12
    var opacity: Double = 0.08

    func body(content: Content) -> some View {
        content
            .shadow(color: Color.accentColor.opacity(opacity), radius: radius, x: 0, y: 0)
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

extension View {
    func glowCardStyle(radius: CGFloat = 12, opacity: Double = 0.08) -> some View {
        modifier(GlowCardStyle(radius: radius, opacity: opacity))
    }
}

/// A prominent, celebratory success notification banner used to confirm that a
/// long-running action (YouTube rip, add music, consolidation, backup) finished.
struct SuccessBanner: View {
    let message: String
    var title: String = "Success"
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white.opacity(0.96))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.68, blue: 0.36),
                            Color(red: 0.10, green: 0.55, blue: 0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: Color.green.opacity(0.38), radius: 14, x: 0, y: 5)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message)")
    }
}