//
//  BrownBearThemeTests.swift
//  BrownBearTests
//
//  Pins the theme-foundation logic: AppTheme → family mapping, the theme-style mapping the window
//  uses, the AppSettings round-trip, and — the crux — that `BrownBearTheme.themed(...)` resolves a
//  token to the right hex for each (family × light/dark). If this regresses, the whole app paints the
//  wrong palette, so these guard the one place the design tokens are decided.
//

import XCTest
import UIKit
@testable import BrownBear

final class BrownBearThemeTests: XCTestCase {

    private var savedTheme: String?

    override func setUp() {
        super.setUp()
        savedTheme = UserDefaults.standard.string(forKey: AppSettings.Key.theme)
    }

    override func tearDown() {
        if let savedTheme { UserDefaults.standard.set(savedTheme, forKey: AppSettings.Key.theme) }
        else { UserDefaults.standard.removeObject(forKey: AppSettings.Key.theme) }
        super.tearDown()
    }

    // MARK: - Mapping

    func testFamilyMapping() {
        XCTAssertEqual(AppTheme.system.family, .clean)
        XCTAssertEqual(AppTheme.light.family, .clean)
        XCTAssertEqual(AppTheme.dark.family, .clean)
        XCTAssertEqual(AppTheme.ogBrown.family, .og)
    }

    func testInterfaceStyleMapping() {
        XCTAssertEqual(ThemeController.interfaceStyle(for: .light), .light)
        XCTAssertEqual(ThemeController.interfaceStyle(for: .dark), .dark)
        XCTAssertEqual(ThemeController.interfaceStyle(for: .system), .unspecified)
        // OG follows the OS light/dark — it must NOT force a style.
        XCTAssertEqual(ThemeController.interfaceStyle(for: .ogBrown), .unspecified)
    }

    func testAppSettingsThemeRoundTrips() {
        AppSettings.theme = .ogBrown
        XCTAssertEqual(AppSettings.theme, .ogBrown)
        AppSettings.theme = .dark
        XCTAssertEqual(AppSettings.theme, .dark)
        // An unset / garbage value defaults to .system.
        UserDefaults.standard.set("nonsense", forKey: AppSettings.Key.theme)
        XCTAssertEqual(AppSettings.theme, .system)
    }

    // MARK: - themed(...) resolution

    private func hex(_ color: UIColor, _ style: UIUserInterfaceStyle) -> UInt32 {
        let resolved = color.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func q(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
        return (q(r) << 16) | (q(g) << 8) | q(b)
    }

    func testThemedResolvesCleanFamily() {
        AppSettings.theme = .system   // clean family
        let token = BrownBearTheme.themed(cleanLight: 0x123456, cleanDark: 0xABCDEF,
                                          ogLight: 0x111111, ogDark: 0x222222)
        XCTAssertEqual(hex(token, .light), 0x123456)
        XCTAssertEqual(hex(token, .dark), 0xABCDEF)
    }

    func testThemedResolvesOGFamily() {
        AppSettings.theme = .ogBrown   // og family
        let token = BrownBearTheme.themed(cleanLight: 0x123456, cleanDark: 0xABCDEF,
                                          ogLight: 0x111111, ogDark: 0x222222)
        XCTAssertEqual(hex(token, .light), 0x111111)
        XCTAssertEqual(hex(token, .dark), 0x222222)
    }

    func testOGSurfaceBasePreservesOriginalWarmHex() {
        // The "OG BrownBear" theme must look identical to the old app — surfaceBase stays the warm
        // off-white / dark-brown it always was.
        AppSettings.theme = .ogBrown
        XCTAssertEqual(hex(BrownBearTheme.Palette.surfaceBase, .light), 0xF7F5F2)
        XCTAssertEqual(hex(BrownBearTheme.Palette.surfaceBase, .dark), 0x14110E)
    }

    func testCleanAccentIsGraphite() {
        AppSettings.theme = .light   // clean family
        // Graphite accent: near-black on light, near-white on dark.
        XCTAssertEqual(hex(BrownBearTheme.Palette.accent, .light), 0x1C1C1E)
        XCTAssertEqual(hex(BrownBearTheme.Palette.accent, .dark), 0xF2F2F7)
    }
}
