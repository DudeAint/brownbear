//
//  AppDelegate.swift
//  BrownBear
//
//  Application entry point. Kept intentionally thin: per-scene UI is owned by SceneDelegate.
//  Process-wide services (the background scheduler in Module 4, persistence in Module 3) are
//  registered here so they are available before any scene connects.
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureGlobalAppearance()
        // Module 4 will register BrownBearBackgroundScheduler's BGTask handlers here.
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    // MARK: Appearance

    private func configureGlobalAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = BrownBearTheme.Palette.chrome
        nav.titleTextAttributes = [.foregroundColor: BrownBearTheme.Palette.textPrimary]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = BrownBearTheme.Palette.accent
        UIWindow.appearance().tintColor = BrownBearTheme.Palette.accent
    }
}
