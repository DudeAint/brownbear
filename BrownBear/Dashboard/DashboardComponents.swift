//
//  DashboardComponents.swift
//  BrownBear
//
//  Small shared building blocks for the dashboard: a wrapping flow layout for pills and a single
//  log-line view.
//

import SwiftUI

/// A simple wrapping layout (iOS 16+) that lays subviews left-to-right, wrapping to new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                widest = max(widest, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        widest = max(widest, rowWidth - spacing)
        return CGSize(width: min(widest, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Renders one log entry: timestamp, optional script name, level-colored message.
struct LogLineView: View {
    let entry: LogEntry

    private var levelColor: Color {
        switch entry.level {
        case .error: return BBTheme.Color.destructive
        case .warn: return BBTheme.Color.accentBright
        case .info: return BBTheme.Color.textPrimary
        case .debug: return BBTheme.Color.textSecondary
        }
    }

    private var time: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: entry.createdAt)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(time)
                .font(.caption2.monospaced())
                .foregroundStyle(BBTheme.Color.textSecondary)
            if entry.context == .background {
                Image(systemName: "clock").font(.caption2).foregroundStyle(BBTheme.Color.textSecondary)
            }
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(levelColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}
