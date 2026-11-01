import Foundation

/// Whether the phone should disable the system idle timer.
///
/// The screen stays awake only while the scene is active and at least one
/// owner wants it: the in-session keep-awake flag, or Demo mode during a
/// session. It is restored when none of those remain. One function so the
/// session and Demo mode cannot switch the timer off out from under each other.
public enum IdleTimerPolicy {
    public static func disableIdleTimer(keepsScreenOn: Bool, demoSession: Bool, sceneActive: Bool) -> Bool {
        sceneActive && (keepsScreenOn || demoSession)
    }
}
