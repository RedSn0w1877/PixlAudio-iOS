import UIKit

/// Who wants the screen kept on.
nonisolated enum ScreenAwakeOwner: Hashable, Sendable {
    /// The lyrics screen, always while it is open (owner, 2026-10-07; Android has a "Keep screen on" switch).
    case lyrics
    /// The sync editor, always while it is open (Android's window flag in `LyricsSyncEditorOverlay`).
    case lyricsSync
}

/// Keeps the screen from locking while any owner asks. `UIApplication.isIdleTimerDisabled` is one flag for the whole
/// app, and the sync editor is presented over the lyrics screen: with one claim per owner, the editor closing never
/// lets the screen lock under a lyrics screen that still wants it on, whatever order their appear and disappear
/// callbacks run in.
@MainActor
enum ScreenAwake {
    private static var owners: Set<ScreenAwakeOwner> = []

    static func set(_ awake: Bool, for owner: ScreenAwakeOwner) {
        if awake { owners.insert(owner) } else { owners.remove(owner) }
        let disabled = !owners.isEmpty
        if UIApplication.shared.isIdleTimerDisabled != disabled { UIApplication.shared.isIdleTimerDisabled = disabled }
    }
}
