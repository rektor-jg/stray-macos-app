import SwiftUI

/// Skala natężenia. Kolor ma nieść informację, a nie dekorować:
/// czerwony znaczy „to jest dużo i prawdopodobnie da się odzyskać".
enum Heat: Int, Sendable {
    case calm = 0, notable = 1, high = 2, severe = 3

    static func forMemory(bytes: UInt64) -> Heat {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1500 { return .severe }
        if mb >= 500  { return .high }
        if mb >= 100  { return .notable }
        return .calm
    }

    static func forCPU(percent: Double) -> Heat {
        if percent >= 70 { return .severe }
        if percent >= 25 { return .high }
        if percent >= 5  { return .notable }
        return .calm
    }

    static func forDisk(bytes: UInt64) -> Heat {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return .severe }
        if gb >= 2  { return .high }
        if gb >= 0.5 { return .notable }
        return .calm
    }
}

extension Heat {
    var color: Color {
        switch self {
        case .calm:    return .secondary
        case .notable: return .yellow
        case .high:    return .orange
        case .severe:  return .red
        }
    }
}

extension Confidence {
    var color: Color {
        switch self {
        case .measured: return .green
        case .traced:   return .teal
        case .inferred: return .gray
        }
    }
    var symbol: String {
        switch self {
        case .measured: return "checkmark.seal.fill"
        case .traced:   return "arrow.triangle.branch"
        case .inferred: return "questionmark.circle"
        }
    }
}

extension Advice {
    var color: Color {
        switch self {
        case .killNow:       return .red
        case .probablyStale: return .orange
        case .keep:          return .green
        case .protected:     return .blue
        }
    }
    var symbol: String {
        switch self {
        case .killNow:       return "xmark.octagon.fill"
        case .probablyStale: return "exclamationmark.triangle.fill"
        case .keep:          return "checkmark.circle.fill"
        case .protected:     return "lock.fill"
        }
    }
    var short: String {
        switch self {
        case .killNow:       return L("advice.kill")
        case .probablyStale: return L("advice.stale")
        case .keep:          return L("advice.keep")
        case .protected:     return L("advice.protected")
        }
    }
}

/// Poziomy pasek udziału — używany i dla procesów, i dla dysku.
struct ShareBar: View {
    let segments: [(value: Double, color: Color)]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.value }, 0.0001)
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.color)
                        .frame(width: max(2, geo.size.width * seg.value / total))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: height / 2))
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var sub: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded)).bold().foregroundStyle(tint)
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }
}
