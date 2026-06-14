//
//  AppDelegate.swift
//  BrownBear
//
//  Application entry point. Kept intentionally thin: per-scene UI is owned by SceneDelegate.
//  Process-wide services (the background scheduler in Module 4, persistence in Module 3) are
//  registered here so they are available before any scene connects.
//

import AVFoundation
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        configureGlobalAppearance()
        configureAudioSessionForVideo()
        // Register background task handlers before launch finishes (required by BGTaskScheduler).
        // Skipped under unit tests, which don't exercise (and can't permit) background tasks.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            BrownBearServices.shared.backgroundScheduler.registerTaskHandlers()
            // Own the notification-center delegate from launch so a cold-start tap on an extension's
            // chrome.notifications banner routes to the right worker.
            WebExtensionNotificationManager.shared.configureDelegate()
        }
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

    // MARK: Audio session

    /// Put the app's audio session in the `.playback` category so web video plays with sound (even with the
    /// ringer silent, like Safari) and — together with the `audio` background mode — keeps running in
    /// Picture-in-Picture when the app is backgrounded. We only set the category; WebKit activates the
    /// session when a video actually plays, so this doesn't grab audio focus from other apps at launch.
    private func configureAudioSessionForVideo() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
