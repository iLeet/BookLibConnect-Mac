import AppKit
import BookLibCore
import SwiftUI

// MARK: - Brand

extension Color {
    /// The teal of the original window chrome.
    static let brand = Color(red: 0.0, green: 0.60, blue: 0.74)
    static let mauve = Color(red: 0.55, green: 0.40, blue: 0.85)
}

// MARK: - Liquid Glass helpers

struct GlassPanel<Content: View>: View {
    var title: String?
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

/// A soft, tinted backdrop so the glass has something to refract.
struct BrandBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.55, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: scheme == .dark
                ? [
                    .brand.opacity(0.55), .indigo.opacity(0.35), .brand.opacity(0.25),
                    .teal.opacity(0.30), .black.opacity(0.10), .purple.opacity(0.28),
                    .black.opacity(0.15), .brand.opacity(0.22), .indigo.opacity(0.30),
                ]
                : [
                    .brand.opacity(0.30), .cyan.opacity(0.18), .mint.opacity(0.22),
                    .teal.opacity(0.14), .white.opacity(0.10), .purple.opacity(0.14),
                    .white.opacity(0.05), .cyan.opacity(0.14), .brand.opacity(0.20),
                ]
        )
        .ignoresSafeArea()
    }
}

// MARK: - State icon

struct StateIcon: View {
    let state: ConversionState

    private var symbol: (name: String, color: Color) {
        switch state {
        case .unknown: ("network.slash", .secondary)
        case .remote: ("globe", .secondary)
        case .download: ("arrow.down.circle", .brand)
        case .licenseGranted: ("key.fill", .brand)
        case .licenseDenied: ("key.slash", .red)
        case .downloading: ("arrow.down.circle.fill", .brand)
        case .downloadError: ("exclamationmark.arrow.triangle.2.circlepath", .red)
        case .localLocked: ("lock.fill", .primary)
        case .unlocking: ("lock.rotation", .orange)
        case .unlockingFailed: ("lock.trianglebadge.exclamationmark", .red)
        case .localUnlocked: ("lock.open.fill", .primary)
        case .exported: ("checkmark.circle.fill", .mauve)
        case .converting: ("arrow.right.circle.fill", .brand)
        case .converted: ("checkmark.circle.fill", .green)
        case .convertedUnknown: ("checkmark.circle", .secondary)
        case .conversionError: ("exclamationmark.circle.fill", .red)
        }
    }

    private var active: Bool { state == .downloading || state == .unlocking || state == .converting }

    var body: some View {
        Image(systemName: symbol.name)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(symbol.color)
            .font(.system(size: 15, weight: .medium))
            .symbolEffect(.pulse, isActive: active)
            .frame(maxWidth: .infinity)
            .help(state.label)
            .accessibilityLabel(state.label)
    }
}

// MARK: - Formatting

enum Fmt {
    static func duration(_ seconds: Int) -> String {
        guard seconds > 0 else { return "" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    static func size(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func hz(_ v: Int) -> String { v > 0 ? "\(v) Hz" : "" }
    static func kbps(_ v: Int) -> String { v > 0 ? "\(v) kb/s" : "" }
    static func year(_ v: Int) -> String { v > 0 ? String(v) : "" }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Cover

struct CoverImage: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "headphones")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
    }
}
