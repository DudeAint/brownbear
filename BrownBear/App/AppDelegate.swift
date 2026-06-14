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

    /// Configure + ACTIVATE the audio session so web video actually plays.
    ///
    /// WebKit drives the media playback CLOCK off the audio render unit, and that unit only runs while the
    /// app's `AVAudioSession` is **active**. BrownBear was only ever setting the CATEGORY, never activating
    /// — the symptom was a video that loads fully and is seekable but whose `currentTime` stays frozen at 0
    /// (page visible, not muted, rate 1, readyState 4). Diagnosed via the page-side media probe; the fix is
    /// to activate the session here.
    ///
    /// `.playback` keeps audio audible with the ringer silent (like Safari) and, with the `audio`
    /// background mode, keeps Picture-in-Picture playing when backgrounded. `.mixWithOthers` means
    /// activating at launch does NOT interrupt another app's audio (and web-video audio mixes with it
    /// rather than pausing it) — a deliberate, minor trade so a freshly launched browser never yanks the
    /// user's music just to be ready to play video. No `mode` is pinned; WebKit sets its own.
    private func configureAudioSessionForVideo() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
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
