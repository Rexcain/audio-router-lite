import SwiftUI

/// Horizontal peak meter, −60…0 dBFS.
struct MeterBar: View {
    let level: Float      // linear peak
    var clipped = false
    var height: CGFloat = 8

    static func fraction(_ level: Float) -> CGFloat {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }

    var body: some View {
        GeometryReader { geo in
            let f = Self.fraction(level)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.75),
                        .init(color: .yellow, location: 0.9),
                        .init(color: .red, location: 1.0),
                    ], startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) { Rectangle().frame(width: geo.size.width * f) }
                if clipped {
                    Rectangle().fill(Color.red).frame(width: 4).frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(height: height)
        .accessibilityLabel("Level")
        .accessibilityValue(level > 0 ? String(format: "%.0f dBFS", 20 * log10(Double(level))) : "silent")
    }
}

/// Label + meter + dB readout for one channel.
struct ChannelMeterRow: View {
    let label: String
    let level: Float
    let clipped: Bool
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).frame(width: 74, alignment: .leading).lineLimit(1).truncationMode(.tail)
            MeterBar(level: level, clipped: clipped)
            Text(level > 0.000_001 ? String(format: "%5.1f", 20 * log10(Double(level))) : "  -∞")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            if let trailing { trailing }
        }
    }
}
