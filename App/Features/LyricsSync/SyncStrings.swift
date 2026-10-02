import Foundation

/// The sync editor's strings: Android's `lyrics_sync_*` keys with their English text (English only, decision 12).
nonisolated enum SyncStrings {
    static let yourselfTitle = String(localized: "lyrics_sync_yourself_title", defaultValue: "Sync the words yourself")
    static let fixTitle = String(localized: "lyrics_sync_fix_title", defaultValue: "Fix my word timing")
    static let resumeTitle = String(localized: "lyrics_sync_resume_title", defaultValue: "Pick up where you left off?")
    static func resumeBody(_ tapped: Int, _ total: Int) -> String {
        String(format: String(localized: "lyrics_sync_resume_body", defaultValue: "You synced %1$d of %2$d words last time."),
               tapped, total)
    }
    static let keepGoing = String(localized: "lyrics_sync_keep_going", defaultValue: "Keep going")
    static let startOver = String(localized: "lyrics_sync_start_over", defaultValue: "Start over")
    static let pasteTitle = String(localized: "lyrics_sync_paste_title", defaultValue: "Paste the lyrics")
    static let pasteBody = String(localized: "lyrics_sync_paste_body",
                                  defaultValue: "Put each line of the song on its own line. We'll use them as they are.")
    static let findOnline = String(localized: "lyrics_sync_find_online", defaultValue: "Find lyrics online")
    static let next = String(localized: "lyrics_sync_next", defaultValue: "Next")
    static let tooLong = String(localized: "lyrics_sync_too_long", defaultValue: "That's a lot of words. Is this the whole album?")
    static let useAnyway = String(localized: "lyrics_sync_use_anyway", defaultValue: "Use anyway")
    static let edit = String(localized: "lyrics_sync_edit", defaultValue: "Edit")
    static let intro1 = String(localized: "lyrics_sync_intro_1", defaultValue: "Play the song.")
    static let intro2 = String(localized: "lyrics_sync_intro_2", defaultValue: "Tap the big button each time a new word starts.")
    static let intro3 = String(localized: "lyrics_sync_intro_3",
                               defaultValue: "Made a mistake? Tap Undo. It rewinds a little so you can try again.")
    static let speedLabel = String(localized: "lyrics_sync_speed_label", defaultValue: "Speed")
    static let speedNormal = String(localized: "lyrics_sync_speed_normal", defaultValue: "Normal")
    static let speedSlower = String(localized: "lyrics_sync_speed_slower", defaultValue: "Slower")
    static let speedSlowest = String(localized: "lyrics_sync_speed_slowest", defaultValue: "Slowest")
    static let speedHelp = String(localized: "lyrics_sync_speed_help", defaultValue: "Slower is easier. The timing still comes out right.")
    static func speedX(_ value: String) -> String {
        String(format: String(localized: "lyrics_sync_speed_x", defaultValue: "%1$@×"), value)
    }
    static let start = String(localized: "lyrics_sync_start", defaultValue: "Start")
    static let gotIt = String(localized: "lyrics_sync_got_it", defaultValue: "Got it, don't show this again")
    static func lineOf(_ line: Int, _ count: Int) -> String {
        String(format: String(localized: "lyrics_sync_line_of", defaultValue: "Line %1$d of %2$d"), line, count)
    }
    static let nextLabel = String(localized: "lyrics_sync_next_label", defaultValue: "Next")
    static let tapHint = String(localized: "lyrics_sync_tap_hint", defaultValue: "Tap when you hear it")
    static let holdTip = String(localized: "lyrics_sync_hold_tip", defaultValue: "Tip: hold it down on long notes")
    static let startSong = String(localized: "lyrics_sync_start_song", defaultValue: "Start the song")
    static let paused = String(localized: "lyrics_sync_paused", defaultValue: "Paused · tap to keep going")
    static let seeResult = String(localized: "lyrics_sync_see_result", defaultValue: "See how it looks")
    static let undo = String(localized: "lyrics_sync_undo", defaultValue: "Undo")
    static let back5 = String(localized: "lyrics_sync_back5", defaultValue: "Back 5 s")
    static let play = String(localized: "lyrics_sync_play", defaultValue: "Play")
    static let pause = String(localized: "lyrics_sync_pause", defaultValue: "Pause")
    static let skipLine = String(localized: "lyrics_sync_skip_line", defaultValue: "Skip this line (time it roughly)")
    static let musicBreak = String(localized: "lyrics_sync_music_break", defaultValue: "Music break")
    static let waitTip = String(localized: "lyrics_sync_wait_tip", defaultValue: "Tip: wait for the singer before tapping")
    static let pastNextLine = String(localized: "lyrics_sync_past_next_line",
                                     defaultValue: "That's past the next line. Tap Undo and try again.")
    static func removedWords(_ count: Int) -> String {
        String(format: String(localized: "lyrics_sync_removed_words", defaultValue: "Removed timing for %d words"), count)
    }
    static let leaveTitle = String(localized: "lyrics_sync_leave_title", defaultValue: "Leave without saving?")
    static let leaveBody = String(localized: "lyrics_sync_leave_body", defaultValue: "Your taps are kept as a draft, so you can come back.")
    static let leave = String(localized: "lyrics_sync_leave", defaultValue: "Leave")
    static let stay = String(localized: "lyrics_sync_stay", defaultValue: "Stay")
    static let songChangedTitle = String(localized: "lyrics_sync_song_changed_title", defaultValue: "The song changed")
    static let songChangedBody = String(localized: "lyrics_sync_song_changed_body", defaultValue: "Your taps are saved as a draft.")
    static func endedEarly(_ count: Int) -> String {
        String(format: String(localized: "lyrics_sync_ended_early", defaultValue: "The song ended before the last %d words."), count)
    }
    static let timeRest = String(localized: "lyrics_sync_time_rest", defaultValue: "Time the rest roughly")
    static let previewTimingQ = String(localized: "lyrics_sync_preview_timing_q", defaultValue: "Words light up too early / too late?")
    static let earlier = String(localized: "lyrics_sync_earlier", defaultValue: "Earlier")
    static let later = String(localized: "lyrics_sync_later", defaultValue: "Later")
    static let fixLine = String(localized: "lyrics_sync_fix_line", defaultValue: "Fix a line")
    static let fixLineHint = String(localized: "lyrics_sync_fix_line_hint", defaultValue: "Tap the line that's off")
    static let rough = String(localized: "lyrics_sync_rough", defaultValue: "Timed roughly")
    static let save = String(localized: "lyrics_sync_save", defaultValue: "Save")
    static let saving = String(localized: "lyrics_sync_saving", defaultValue: "Saving…")
    static let keepTapping = String(localized: "lyrics_sync_keep_tapping", defaultValue: "Keep tapping")
    static let saved = String(localized: "lyrics_sync_saved", defaultValue: "Saved. The words will light up from now on.")
    static let saveFailed = String(localized: "lyrics_sync_save_failed", defaultValue: "Couldn't save. Your taps are kept as a draft.")
    static let tryAgain = String(localized: "lyrics_sync_try_again", defaultValue: "Try again")
    static let share = String(localized: "lyrics_sync_share", defaultValue: "Share lyrics file")
    static let shareLrc = String(localized: "lyrics_sync_share_lrc", defaultValue: "For most apps (.lrc)")
    static let shareTtml = String(localized: "lyrics_sync_share_ttml", defaultValue: "Most detail (.ttml)")
    static let fixTiming = String(localized: "lyrics_sync_fix_timing", defaultValue: "Fix timing")
    static let remove = String(localized: "lyrics_sync_remove", defaultValue: "Remove my timing")
    static let removeBody = String(localized: "lyrics_sync_remove_body",
                                   defaultValue: "This deletes the timing you made and goes back to the lyrics we found online.")
    static let alreadyTimed = String(localized: "lyrics_sync_already_timed",
                                     defaultValue: "These lyrics already have word timing. Tap Start to redo it, or Fix a line in the preview.")
    static let loading = String(localized: "lyrics_sync_loading", defaultValue: "Getting the song ready…")
    static func nudgeValue(_ ms: Int) -> String {
        String(format: String(localized: "lyrics_sync_nudge_value", defaultValue: "%1$+d ms"), ms)
    }
    static let fileSaved = String(localized: "lyrics_sync_file_saved", defaultValue: "Lyrics file saved")
    static let fileFailed = String(localized: "lyrics_sync_file_failed", defaultValue: "Couldn't save the file")
    static let noResults = String(localized: "lyrics_sync_no_results", defaultValue: "No lyrics found online. Paste them instead.")
    static let pickResult = String(localized: "lyrics_sync_pick_result", defaultValue: "Pick the right lyrics")
    static let noSong = String(localized: "lyrics_sync_no_song", defaultValue: "Play the song first, then sync its words.")

    static let ok = String(localized: "common_ok", defaultValue: "OK")
    static let cancel = String(localized: "common_cancel", defaultValue: "Cancel")
    static let commonUndo = String(localized: "common_undo", defaultValue: "Undo")
    static let close = String(localized: "common_close", defaultValue: "Close")
    static let commonRemove = String(localized: "common_remove", defaultValue: "Remove")
}
