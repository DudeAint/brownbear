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

        // Apply the saved appearance (clean Light/Dark/System or OG BrownBear) to the window.
        ThemeController.applyAtLaunch(to: window)

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

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Skip during unit tests (no full app stack booted; see willConnectTo).
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        // Re-activate the audio session every foreground — an active session can be deactivated while the
        // app is backgrounded or by an interruption, and without this the next web video silently stalls
        // (currentTime frozen at 0). Cheap + idempotent.
        AudioSessionManager.activateForVideo()
        // Opportunistic catch-up: iOS background tasks are unreliable, so run any @crontab/@background
        // script that has come due since its last run whenever the app is opened. This is what makes
        // scheduled scripts actually run (and get a "last run") on a real device.
        BrownBearServices.shared.backgroundScheduler.runDueScriptsOnForeground()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Ask the OS to wake us to run due @crontab scripts (best-effort).
        BrownBearServices.shared.backgroundScheduler.scheduleNextRun()
    }
}
