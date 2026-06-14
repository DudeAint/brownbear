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

    /// `.playback` (audible with the ringer silent, like Safari; keeps PiP/background audio alive with the
    /// `audio` background mode). We do NOT pass `.mixWithOthers`: a mixable "secondary" session does not
    /// reliably drive WebKit's media clock, so video can stay frozen. The cost is that activating takes
    /// audio focus from another app — acceptable, and what Safari-like media playback does anyway.
    static func activateForVideo() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }
}
