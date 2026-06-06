//
//  SceneDelegate.swift
//  BrownBear
//
//  Owns the window for a single scene and roots the browser. The browser view controller is
//  the heart of the app; everything else (tab grid, dashboard) is presented from it.
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.tintColor = BrownBearTheme.Palette.accent

        // Under unit tests the host app must not boot the full browser/WebKit stack — the logic
        // tests don't need it, and doing so just couples them to app launch. Install a blank root.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
            self.window = window
            return
        }

        let browser = BrownBearBrowserViewController()
        window.rootViewController = browser
        window.makeKeyAndVisible()

        self.window = window

        // Open the user's first tab on a friendly start page.
        browser.openInitialTabIfNeeded()

        // Honor a URL passed in at launch (e.g. from another app).
        if let urlContext = connectionOptions.urlContexts.first {
            browser.handleExternalURL(urlContext.url)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let context = URLContexts.first,
              let browser = window?.rootViewController as? BrownBearBrowserViewController else { return }
        browser.handleExternalURL(context.url)
    }
}
