//
//  TabGroup.swift
//  BrownBear
//
//  A named, colored grouping of tabs (Chrome/Safari "tab groups", Orion "spaces"). A tab belongs to at
//  most one group via `Tab.groupID`; the group's definition lives in `TabManager.groups` and is persisted
//  so groups survive relaunch. Foundation-only (no UIKit) so any layer can read it; the UI builds a
//  UIColor from `color.hex`. Private tabs are never grouped (incognito leaves no trace).
//

import Foundation

/// One tab group: a stable id, a user-facing name, and a color used for its dot/label across the UI.
struct TabGroup: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var color: TabGroupColor

    init(id: UUID = UUID(), name: String, color: TabGroupColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}

/// The preset palette a tab group can use — the iOS system accent hues, which read well on both light
/// and dark surfaces. Codable by `rawValue` so persisted groups decode stably even if the order changes.
enum TabGroupColor: String, CaseIterable, Codable, Identifiable {
    case grey, blue, red, orange, yellow, green, cyan, purple, pink

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .grey: return "Grey"
        case .blue: return "Blue"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .cyan: return "Cyan"
        case .purple: return "Purple"
        case .pink: return "Pink"
        }
    }

    /// 0xRRGGBB for the group's dot/label. Build a UIColor with `UIColor(hex:)` at the UI layer.
    var hex: UInt32 {
        switch self {
        case .grey: return 0x8E8E93
        case .blue: return 0x0A84FF
        case .red: return 0xFF453A
        case .orange: return 0xFF9F0A
        case .yellow: return 0xFFD60A
        case .green: return 0x32D74B
        case .cyan: return 0x64D2FF
        case .purple: return 0xBF5AF2
        case .pink: return 0xFF375F
        }
    }

    /// The next color to use for a freshly-created group, cycling through the palette so back-to-back new
    /// groups get visually distinct colors instead of all defaulting to the same one.
    static func suggested(forExistingCount count: Int) -> TabGroupColor {
        let all = allCases
        return all[((count % all.count) + all.count) % all.count]
    }
}
