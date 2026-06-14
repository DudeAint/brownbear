//
//  AudioSessionManager.swift
//  BrownBear
//
//  Configures + ACTIVATES the app audio session so WebKit web video actually plays. WebKit drives the
//  media playback CLOCK off the audio render unit, and that unit only runs while the app's AVAudioSession
//  is *active* — setting the category alone is not enough (the symptom was video that loads fully and is
//  seekable but whose currentTime stays frozen at 0). We activate at launch AND whenever the app returns
//  to the foreground, because an active session can be deactivated while backgrounded or by an interruption
//  (a phone call, another app) — and without a re-activation the next video would silently stall.
//

import AVFoundation

enum AudioSessionManager {

    /// Set ONLY the `.playback` category (audible with the ringer silent, like Safari; keeps PiP/background
    /// audio alive with the `audio` background mode). We deliberately do NOT call `setActive(true)`:
    /// Chromium iOS / Safari leave activation to WebKit, which activates its own media session at the moment
    /// a video plays. The app force-activating the session ahead of time put it in a state WebKit's media
    /// session manager didn't expect — and the clock stayed frozen even WITH the session active (verified on
    /// the `build=b2` build). Letting WebKit own activation matches the engines where web video works.
    static func configureForVideo() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }
}
