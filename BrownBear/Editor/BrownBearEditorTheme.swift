//
//  BrownBearEditorTheme.swift
//  BrownBear
//
//  A Runestone `Theme` in BrownBear's palette: dark, monospaced, amber-accented gutter. Token
//  (syntax-highlight) colors are wired here too; they take effect once a Tree-sitter JavaScript
//  language is attached (a planned follow-up — the editor ships with line numbers + this theme).
//

import Runestone
import UIKit

final class BrownBearEditorTheme: Runestone.Theme {

    let font: UIFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    let textColor = BrownBearTheme.Palette.textPrimary

    let gutterBackgroundColor = BrownBearTheme.Palette.chrome
    let gutterHairlineColor = BrownBearTheme.Palette.separator

    let lineNumberColor = BrownBearTheme.Palette.textSecondary
    let lineNumberFont: UIFont = .monospacedSystemFont(ofSize: 11, weight: .regular)

    // Layout tuning (these have protocol-extension defaults in Runestone; set explicitly so the
    // editor reads comfortably and to satisfy the requirements regardless of package version).
    let lineHeightMultiplier: CGFloat = 1.2
    let kern: CGFloat = 0
    let gutterMinimumCharacterCount: Int = 2

    let selectedLineBackgroundColor = BrownBearTheme.Palette.accent.withAlphaComponent(0.10)
    let selectedLinesLineNumberColor = BrownBearTheme.Palette.accent
    let selectedLinesGutterBackgroundColor = BrownBearTheme.Palette.chrome

    let invisibleCharactersColor = BrownBearTheme.Palette.textSecondary.withAlphaComponent(0.4)

    let pageGuideHairlineColor = BrownBearTheme.Palette.separator
    let pageGuideBackgroundColor = BrownBearTheme.Palette.omniboxFill
    let markedTextBackgroundColor = BrownBearTheme.Palette.accent.withAlphaComponent(0.2)

    /// Token colors keyed by Tree-sitter highlight capture name (used once a language is attached).
    func textColor(for highlightName: String) -> UIColor? {
        switch highlightName {
        case "keyword", "keyword.function", "keyword.return", "conditional", "repeat":
            return UIColor(hex: 0xFF9E64)
        case "string", "string.special": return UIColor(hex: 0x9ECE6A)
        case "comment": return BrownBearTheme.Palette.textSecondary
        case "number", "boolean", "constant.builtin": return UIColor(hex: 0xF7768E)
        case "function", "function.method", "function.builtin": return UIColor(hex: 0x7AA2F7)
        case "property", "variable.builtin": return UIColor(hex: 0xBB9AF7)
        case "operator", "punctuation.delimiter": return BrownBearTheme.Palette.textSecondary
        default: return nil
        }
    }

    func fontTraits(for highlightName: String) -> FontTraits {
        switch highlightName {
        case "keyword", "keyword.function", "keyword.return", "conditional", "repeat":
            return .bold
        case "comment": return .italic
        default: return []
        }
    }

    func shadow(for highlightName: String) -> NSShadow? { nil }

    @available(iOS 16, *)
    func highlightedRange(forFoundTextRange foundTextRange: NSRange,
                          ofStyle style: UITextSearchFoundTextStyle) -> HighlightedRange? {
        nil
    }
}
