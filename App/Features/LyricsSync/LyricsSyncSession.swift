import Foundation
import Observation
import PixlLyrics
import PixlModel

/// Where the editor should start (Android `SyncEntry`).
nonisolated enum SyncEntry: Sendable, Equatable {
    /// Decide from the song's lyrics and any draft (the lyrics screen's entry points).
    case auto
    /// Straight to "Paste the lyrics", pre-filled with the current words ("Change the words").
    case words
    /// Straight to the preview of the saved timing ("Fix timing").
    case fixTiming
}

/// The editor's screens (Android `SyncPhase`, spec §2).
nonisolated enum SyncPhase: Sendable, Equatable {
    case closed
    case loading
    case resumePrompt(tapped: Int, total: Int)
    case needWords
    case intro
    /// Ready, tapping and paused: one screen, the pad's label follows the play state.
    case tapping
    case preview
    /// Re-tapping one line from the preview; later lines keep their timing.
    case fixLine(Int)
    /// The song is already user-synced: Fix timing · Start over · Remove my timing.
    case manage
    case error(String)

    var isTapScreen: Bool {
        switch self {
        case .tapping, .fixLine: true
        default: false
        }
    }
}

nonisolated enum SyncDialog: Sendable, Equatable { case none, leave, songChanged, endedEarly, saveFailed }

nonisolated enum SyncNoticeKind: Sendable, Equatable { case removedWords, waitTip, pastNextLine }

/// A transient message shown as a pill over the controls; `id` changes for every new notice.
nonisolated struct SyncNotice: Sendable, Equatable {
    let id: Int
    let kind: SyncNoticeKind
    var count = 0
    var canUndo = false
}

/// One "Find lyrics online" hit.
nonisolated struct SyncSearchHit: Sendable, Hashable {
    let label: String
    let text: String
}

/// The finished result drawn by the karaoke renderer in Preview.
nonisolated struct SyncPreview: Sendable, Equatable {
    let prepared: PreparedLyrics
    /// Draft line index for each prepared line index.
    let draftLineForPrepared: [Int]
    let hasRoughLines: Bool
}

/// "Sync it yourself": the tap-to-sync editor's state and its player session — a port of Android's
/// `LyricsSyncEditorStateHolder` (spec §2–§5). The pure maths is PixlLyrics' `LyricsTapSync`; this class feeds it exact
/// player positions and turns its results into seeks, drafts and the saved `LyricsDoc`.
///
/// While open it owns the player: it pauses, suspends crossfades and the hand-over to the next song (pausing at the
/// end of the song instead), and changes the speed. `close()` restores all of it, whatever the reason for closing.
/// Fine-grained observable properties: a tap changes `draft` (and the session counters), never per-frame state —
/// the position is read on demand.
@Observable
final class LyricsSyncSession {
    static let speeds: [Float] = [1, 0.75, 0.5]
    static let introShowCount = 2
    static let openWaitMs: Int64 = 8_000
    static let draftSaveDelayMs: Int64 = 1_000
    static let fixLineReturnMs: Int64 = 1_000
    static let finishPollMs: Int64 = 100
    static let finishTailMs: Int64 = 1_500
    nonisolated static let previewStartPrerollMs: Int64 = 2_000
    nonisolated static let previewLinePrerollMs: Int64 = 1_500
    static let removedWordsNoticeMin = 3
    /// Preview-only mark at the end of a roughly timed line.
    nonisolated static let roughMark = " ≈"

    // MARK: Observable state (Android `SyncUiState` + phase)

    private(set) var phase: SyncPhase = .closed
    private(set) var songId = ""
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var song: Song?
    private(set) var draft: SyncDraft?
    private(set) var origin: SyncDraftOrigin = .none
    private(set) var wordsSeed = ""
    private(set) var searching = false
    private(set) var searchHits: [SyncSearchHit]?
    private(set) var speed: Float = 1
    private(set) var isPlaying = false
    /// The user pressed "Start the song" (or resumed a draft) in this session.
    private(set) var started = false
    private(set) var sessionTaps = 0
    private(set) var fixLine: Int?
    var dialog: SyncDialog = .none
    private(set) var endedEarlyWords = 0
    private(set) var notice: SyncNotice?
    private(set) var isSaving = false
    private(set) var preview: SyncPreview?
    private(set) var lineSelectMode = false
    private(set) var haptics = true
    private(set) var offsetMs = LyricsTapSync.defaultOffsetSpeakerMs
    /// Bumped by every pad press (the view's `sensoryFeedback` trigger).
    private(set) var pressCount = 0
    /// Fixed position for UI tests (preview and the music-break ring).
    @ObservationIgnored var frozenPositionMs: Int64?

    // MARK: Dependencies

    @ObservationIgnored let player: LyricsSyncPlayer
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let lyricsStore: LyricsStore
    @ObservationIgnored private let lyricsController: LyricsController
    @ObservationIgnored private let draftStore: LyricsSyncDraftStore
    @ObservationIgnored private let preferences: LyricsSyncPreferences
    @ObservationIgnored private let songLookup: (String) -> Song?
    @ObservationIgnored private let isUITest: Bool
    /// Called once the session has closed (the view dismisses the cover).
    @ObservationIgnored var onClosed: (() -> Void)?

    // MARK: Session state (Android `Session`)

    @ObservationIgnored private var sessionOpen = false
    @ObservationIgnored private var previousSpeed: Float = 1
    @ObservationIgnored private var bluetooth = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saved = false
    @ObservationIgnored private var lastTapUptimeMs = Int64.min / 2
    @ObservationIgnored private var shownWaitTip = false
    @ObservationIgnored private var introSeenCount = 0
    @ObservationIgnored private var storedDraft: SyncDraft?
    @ObservationIgnored private var seedDraft: SyncDraft?
    @ObservationIgnored private var undoSnapshot: (draft: SyncDraft, positionMs: Int64)?
    @ObservationIgnored private var noticeCounter = 0
    /// Screenshot states (`-syncStep tapNotice`): the notice stays up instead of timing out before the shot.
    @ObservationIgnored private var holdsDemoNotice = false

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var draftSaveTask: Task<Void, Never>?
    @ObservationIgnored private var undoSeekTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var fixLineReturnTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewSeekTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var unloadedTask: Task<Void, Never>?

    init(player: LyricsSyncPlayer, settings: SettingsStore, lyricsStore: LyricsStore, lyricsController: LyricsController,
         draftStore: LyricsSyncDraftStore, preferences: LyricsSyncPreferences, isUITest: Bool,
         songLookup: @escaping (String) -> Song?) {
        self.player = player
        self.settings = settings
        self.lyricsStore = lyricsStore
        self.lyricsController = lyricsController
        self.draftStore = draftStore
        self.preferences = preferences
        self.isUITest = isUITest
        self.songLookup = songLookup
        player.onSongEnded = { [weak self] in self?.onSongEnded() }
    }

    /// The exact media position for per-frame readers (the preview renderer, the music-break ring).
    func positionMs() -> Int64 { frozenPositionMs ?? player.positionMs() }

    // MARK: - Opening and closing

    /// Opens the editor for `songId` (Android `requestOpen` / `open`): starts that song paused when something else
    /// is playing, then decides the first screen.
    func open(songId requested: String, entry: SyncEntry) {
        guard phase == .closed else { return }
        let target = player.currentSong?.id == requested ? player.currentSong : (songLookup(requested) ?? player.currentSong)
        guard let target else {
            phase = .error(SyncStrings.noSong)
            return
        }
        if player.currentSong?.id != target.id {
            player.playback.play([target], startIndex: 0, startPositionMs: 0, playWhenReady: false)
        }
        song = target
        songId = target.id
        title = target.title
        artist = target.displayArtist
        phase = .loading
        startSession()
        loadTask = Task { [weak self] in await self?.load(target, entry: entry) }
    }

    private func startSession() {
        sessionOpen = true
        dirty = false
        saved = false
        previousSpeed = player.currentRate
        bluetooth = LyricsSyncPlayer.isBluetoothRoute()
        pause()
        player.beginSession()
        isPlaying = false
        let store = draftStore
        Task.detached(priority: .utility) { _ = await store.pruneOlderThan() }
    }

    private func load(_ song: Song, entry: SyncEntry) async {
        let lyricsSettings = settings.lyrics
        offsetMs = bluetooth ? lyricsSettings.tapOffsetBluetoothMs : lyricsSettings.tapOffsetSpeakerMs
        haptics = lyricsSettings.syncHaptics
        let defaultSpeed = Float(lyricsSettings.syncDefaultSpeed)
        speed = Self.speeds.contains(defaultSpeed) ? defaultSpeed : 1
        introSeenCount = preferences.introSeenCount
        if speed != player.currentRate { player.setRate(speed) }

        let lyrics = await currentLyrics(for: song)
        guard sessionOpen, songId == song.id else { return }

        if entry == .words {
            wordsSeed = Self.plainText(of: lyrics)
            phase = .needWords
            return
        }

        let seed = await Task.detached(priority: .userInitiated) {
            LyricsTapSync.buildDraft(song: song, lyrics: lyrics, pasted: nil)
        }.value
        guard sessionOpen, songId == song.id else { return }
        seedDraft = seed.draft
        origin = seed.origin

        if entry == .fixTiming, let seedDraft = seed.draft {
            setDraft(seedDraft, dirty: false)
            goToPreview()
            return
        }

        let stored = await draftStore.load(song.id)
        guard sessionOpen, songId == song.id else { return }
        if let stored, stored.tappedCount > 0 {
            storedDraft = stored
            phase = .resumePrompt(tapped: stored.tappedCount, total: stored.tappableCount)
            return
        }
        startFromSeed(seed.draft, origin: seed.origin)
    }

    /// The song's lyrics: what the lyrics screen has loaded for it, else what is stored (Android `getStoredLyrics`).
    private func currentLyrics(for song: Song) async -> Lyrics? {
        if case .loaded(let id, let lyrics, _) = lyricsStore.state, id == song.id { return lyrics }
        if isUITest { return LyricsDemoContent.lyrics(LyricsLaunchOptions.current.demo) }
        return await lyricsController.syncService?.storedLyricsAsync(for: song)?.lyrics
    }

    private func startFromSeed(_ seedDraft: SyncDraft?, origin: SyncDraftOrigin) {
        guard sessionOpen else { return }
        guard let seedDraft else {
            wordsSeed = ""
            phase = .needWords
            return
        }
        switch origin {
        case .userSynced:
            setDraft(seedDraft, dirty: false)
            phase = .manage
        case .wordSynced:
            setDraft(seedDraft, dirty: false)
            phase = .intro
        default:
            if introSeenCount < Self.introShowCount {
                setDraft(seedDraft, dirty: false)
                phase = .intro
            } else {
                beginTapping(seedDraft)
            }
        }
    }

    /// Back / ✕: asks first when there are taps that would otherwise be left as a draft.
    func requestClose() {
        let hasWork = sessionOpen && dirty && (draft?.tappedCount ?? 0) > 0
        if hasWork && (phase.isTapScreen || phase == .preview) {
            pause()
            dialog = .leave
        } else {
            close()
        }
    }

    /// The system back gesture: steps out of line-pick mode and dialogs first.
    func onBack() {
        if lineSelectMode {
            lineSelectMode = false
            return
        }
        if dialog != .none {
            dismissDialog()
            return
        }
        requestClose()
    }

    /// Ends the session for any reason and puts the player back as it was. Idempotent.
    func close() {
        let wasOpen = sessionOpen
        sessionOpen = false
        for task in [loadTask, undoSeekTask, finishTask, fixLineReturnTask, previewTask, previewSeekTask, searchTask,
                     draftSaveTask, unloadedTask] {
            task?.cancel()
        }
        if wasOpen {
            if let toFlush = draft, dirty, !saved, toFlush.tappedCount > 0 {
                let store = draftStore
                Task.detached(priority: .utility) { _ = await store.save(toFlush) }
            }
            player.endSession(restoreRate: previousSpeed)
        }
        let wasClosed = phase == .closed
        phase = .closed
        if !wasClosed || wasOpen { onClosed?() }
    }

    /// The app went to the background: pause and keep the taps.
    func onHostStopped() {
        guard sessionOpen else { return }
        pause()
        flushDraft()
    }

    /// The store's current song changed (Android's `currentSong` collector).
    func currentSongChanged(to id: String?) {
        guard sessionOpen, phase != .closed else { return }
        unloadedTask?.cancel()
        if id == nil {
            // The player unloaded; a brief nil can happen during a queue rebuild, so only close if it stays.
            unloadedTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, let self, self.sessionOpen, self.player.currentSong == nil else { return }
                self.close()
            }
        } else if id != songId {
            pause()
            flushDraft()
            dialog = .songChanged
        }
    }

    /// The store's play state changed (the engine paused by itself, an interruption…).
    func playingChanged(_ playing: Bool) {
        player.storeReported(playing: playing)
        if isPlaying != playing { isPlaying = playing }
    }

    func dismissDialog() {
        if dialog == .songChanged {
            close()
        } else {
            dialog = .none
        }
    }

    func confirmLeave() { close() }

    // MARK: - Resume prompt, manage, words, intro

    func resumeKeepGoing() {
        guard let stored = storedDraft else { return }
        storedDraft = nil
        setDraft(stored, dirty: true)
        if stored.isFinished { goToPreview() } else { beginTapping(stored, resume: true) }
    }

    func resumeStartOver() {
        storedDraft = nil
        deleteDraftFile()
        if let seedDraft, origin == .userSynced || origin == .wordSynced {
            beginTapping(LyricsTapSync.clearAll(seedDraft))
        } else {
            startFromSeed(seedDraft, origin: origin)
        }
    }

    func manageFixTiming() { goToPreview() }

    func manageStartOver() {
        guard let current = draft else { return }
        deleteDraftFile()
        beginTapping(LyricsTapSync.clearAll(current))
    }

    /// "Remove my timing": deletes the user's sync and goes back to the lyrics found online.
    func removeMyTiming() {
        guard let song else { return }
        saved = true
        deleteDraftFile()
        lyricsController.reset(song: song)
        close()
    }

    func findLyricsOnline() {
        guard let song else { return }
        searchTask?.cancel()
        searching = true
        searchHits = nil
        let service = lyricsController.syncService
        searchTask = Task { [weak self] in
            var hits: [SyncSearchHit] = []
            if let service, case .success(let results) = await service.searchCandidates(song: song) {
                hits = results.compactMap { result in
                    let text = Self.plainText(of: result.lyrics)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                    let label = [result.record.name, result.record.artistName]
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .joined(separator: " · ")
                    return SyncSearchHit(label: label, text: text)
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.searching = false
            self.searchHits = hits
        }
    }

    func clearSearchHits() {
        searchTask?.cancel()
        searching = false
        searchHits = nil
    }

    /// "Next" on the words screen: the text becomes plain lyrics to tap.
    func submitWords(_ text: String) {
        guard let song, sessionOpen else { return }
        Task { [weak self] in
            let seed = await Task.detached(priority: .userInitiated) {
                LyricsTapSync.buildDraft(song: song, lyrics: nil, pasted: text)
            }.value
            guard let self, self.sessionOpen, self.songId == song.id, let built = seed.draft else { return }
            self.origin = .plain
            self.wordsSeed = text
            if self.introSeenCount < Self.introShowCount {
                self.setDraft(built, dirty: false)
                self.phase = .intro
            } else {
                self.beginTapping(built)
            }
        }
    }

    /// Intro "Start" (`dontShowAgain` = "Got it, don't show this again").
    func startFromIntro(dontShowAgain: Bool) {
        guard let current = draft else { return }
        introSeenCount = dontShowAgain ? Self.introShowCount : introSeenCount + 1
        preferences.introSeenCount = introSeenCount
        let alreadyTimed = origin == .wordSynced || origin == .userSynced
        beginTapping(alreadyTimed ? LyricsTapSync.clearAll(current) : current)
    }

    // MARK: - Tapping

    private func beginTapping(_ start: SyncDraft, resume: Bool = false) {
        pause()
        setDraft(start, dirty: resume || draft != start)
        fixLine = nil
        lineSelectMode = false
        started = resume
        preview = nil
        phase = .tapping
        let seek: Int64?
        if resume {
            seek = lastStampedStart(start).map { $0 - scaled(LyricsTapSync.undoPrerollMs) }
        } else {
            let firstAnchor = start.lines.first { !$0.locked }?.anchorMs ?? 0
            seek = firstAnchor - LyricsTapSync.anchorPrerollMs
        }
        seekTo(max(0, seek ?? 0))
    }

    /// Finger down on the tap pad, stamped with the touch's own timestamp (`eventUptime`, seconds on the
    /// `ProcessInfo.systemUptime` clock). Returns the index of the stamped word (so the release can mark a held end),
    /// or -1.
    func onTapDown(eventUptime: TimeInterval) -> Int {
        pressCount &+= 1
        guard phase.isTapScreen, sessionOpen, let current = draft, dialog == .none else { return -1 }
        if phase == .tapping && current.isFinished {
            goToPreview()
            return -1
        }
        if !player.playWhenReady {
            play()
            started = true
            return -1
        }
        let eventMs = Self.uptimeMs(eventUptime)
        if eventMs - lastTapUptimeMs < LyricsTapSync.bounceMs { return -1 }
        lastTapUptimeMs = eventMs

        let tapSpeed = speed
        let raw = LyricsTapSync.rawTapPositionMs(positionMs: player.positionMs(),
                                                 nowUptimeMs: Self.uptimeMs(ProcessInfo.processInfo.systemUptime),
                                                 eventUptimeMs: eventMs, speed: tapSpeed)
        let index = LyricsTapSync.nextTappable(current, from: current.cursor)
        let step = LyricsTapSync.tap(current, rawStartMs: raw, speed: tapSpeed, offsetMs: offsetMs, scopeLine: fixLine)
        if step.draft == current { return -1 }
        setDraft(step.draft, dirty: true)
        sessionTaps += 1
        started = true
        if step.pastNextLine { showNotice(.pastNextLine) }
        if step.tapBeforeAnchor && !shownWaitTip {
            shownWaitTip = true
            showNotice(.waitTip)
        }

        let next = step.draft
        if let fix = fixLine {
            let nextIndex = LyricsTapSync.nextTappable(next, from: next.cursor)
            let leftLine = nextIndex >= next.tokens.count || next.tokens[nextIndex].line != fix
            if leftLine {
                fixLineReturnTask?.cancel()
                fixLineReturnTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(Self.fixLineReturnMs))
                    guard !Task.isCancelled else { return }
                    self?.goToPreview(focusLine: fix)
                }
            }
        } else if next.isFinished {
            scheduleFinishPause(next)
        }
        return index
    }

    /// Finger up: a hold of at least 350 ms marks the end of the word it stamped.
    func onTapUp(tokenIndex: Int, downUptime: TimeInterval, upUptime: TimeInterval) {
        let downMs = Self.uptimeMs(downUptime), upMs = Self.uptimeMs(upUptime)
        guard tokenIndex >= 0, upMs - downMs >= LyricsTapSync.holdThresholdMs, let current = draft else { return }
        let raw = LyricsTapSync.rawTapPositionMs(positionMs: player.positionMs(),
                                                 nowUptimeMs: Self.uptimeMs(ProcessInfo.processInfo.systemUptime),
                                                 eventUptimeMs: upMs, speed: speed)
        let released = LyricsTapSync.release(current, tokenIndex: tokenIndex, rawEndMs: raw, speed: speed, offsetMs: offsetMs)
        if released != current { setDraft(released, dirty: true) }
    }

    /// Undo: pops one tap now; the rewind seek runs 250 ms after the last of a burst of presses.
    func undo() {
        guard let current = draft else { return }
        let step = LyricsTapSync.undo(current, speed: speed, offsetMs: offsetMs, scopeLine: fixLine)
        if step.draft == current { return }
        finishTask?.cancel()
        fixLineReturnTask?.cancel()
        setDraft(step.draft, dirty: true)
        guard let target = step.seekToMs else { return }
        undoSeekTask?.cancel()
        undoSeekTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(LyricsTapSync.undoSeekDelayMs))
            guard !Task.isCancelled else { return }
            self?.seekTo(target)
        }
    }

    /// Back 5 s: forgets taps after the new position.
    func rewind() {
        guard let current = draft else { return }
        let position = player.positionMs()
        let step = LyricsTapSync.rewind(current, positionMs: position, offsetMs: offsetMs, scopeLine: fixLine)
        applyDestructive(before: current, positionMs: position, step: step)
    }

    /// A tap on a shown line at or before the current one: re-tap from that line.
    func jumpToLine(_ lineIndex: Int) {
        guard phase == .tapping, let current = draft else { return }
        let position = player.positionMs()
        let step = LyricsTapSync.jumpToLine(current, lineIndex: lineIndex, speed: speed, offsetMs: offsetMs)
        if step.draft == current && step.seekToMs == nil { return }
        // A jump the user picked by touching a line always offers Undo if it erased anything.
        applyDestructive(before: current, positionMs: position, step: step, noticeMin: 0)
    }

    private func applyDestructive(before: SyncDraft, positionMs: Int64, step: SyncStep,
                                  noticeMin: Int = LyricsSyncSession.removedWordsNoticeMin) {
        finishTask?.cancel()
        fixLineReturnTask?.cancel()
        undoSeekTask?.cancel()
        if step.draft != before { setDraft(step.draft, dirty: true) }
        if let seek = step.seekToMs { seekTo(seek) }
        if step.clearedCount > noticeMin {
            undoSnapshot = (before, positionMs)
            showNotice(.removedWords, count: step.clearedCount, canUndo: true)
        }
    }

    /// The notice's "Undo" after a rewind or jump: restores the taps and the position.
    func undoRemoval() {
        guard let snapshot = undoSnapshot else { return }
        undoSnapshot = nil
        setDraft(snapshot.draft, dirty: true)
        seekTo(snapshot.positionMs)
        dismissNotice()
    }

    func skipLine() {
        guard let current = draft else { return }
        let step = LyricsTapSync.skipLine(current, offsetMs: offsetMs)
        if step.draft == current { return }
        setDraft(step.draft, dirty: true)
        if step.draft.isFinished { scheduleFinishPause(step.draft) }
    }

    func togglePlay() {
        if player.playWhenReady {
            pause()
        } else {
            play()
            started = true
        }
    }

    func setSpeed(_ newSpeed: Float) {
        guard Self.speeds.contains(newSpeed) else { return }
        speed = newSpeed
        player.setRate(newSpeed)
    }

    func setHaptics(_ enabled: Bool) {
        haptics = enabled
        settings.lyrics.syncHaptics = enabled
    }

    /// The song ended with words left: "Keep going" seeks to 2 s before the last tap.
    func endedKeepGoing() {
        guard let current = draft else { return }
        dialog = .none
        seekTo(max(0, (lastStampedStart(current) ?? 0) - LyricsTapSync.undoPrerollMs))
    }

    /// "Time the rest roughly": spread the remaining words and show the result.
    func endedTimeRest() {
        guard let current = draft else { return }
        dialog = .none
        let step = LyricsTapSync.fillRest(current, offsetMs: offsetMs)
        setDraft(step.draft, dirty: true)
        goToPreview()
    }

    private func onSongEnded() {
        isPlaying = false
        guard let current = draft, phase == .tapping, !current.isFinished else { return }
        endedEarlyWords = current.remainingCount
        dialog = .endedEarly
    }

    /// After the last word: play on to the end of the last line + 1.5 s, then pause.
    private func scheduleFinishPause(_ finished: SyncDraft) {
        finishTask?.cancel()
        let offset = offsetMs
        finishTask = Task { [weak self] in
            let end = await Task.detached(priority: .userInitiated) {
                LyricsTapSync.resolveTiming(finished, offsetMs: offset)?.endsMs.max()
            }.value
            guard let end else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.finishPollMs))
                guard !Task.isCancelled, let self, self.player.playWhenReady else { return }
                if self.player.positionMs() >= end + Self.finishTailMs {
                    self.pause()
                    return
                }
            }
        }
    }

    // MARK: - Preview, fix a line, save, share

    func goToPreview(focusLine: Int? = nil) {
        guard let before = draft else { return }
        if before.tappedCount == 0 && before.tappableCount > 0 { return }
        // After "Fix a line" the cursor sits on the next (already timed) line: point it at the first word still
        // untimed, so "Keep tapping" never re-stamps a timed word.
        let firstUntimed = before.tokens.indices.first { i in
            before.tokens[i].rawStartMs == nil && !before.lines[before.tokens[i].line].locked
        } ?? before.tokens.count
        var current = before
        if before.cursor != firstUntimed {
            current.cursor = firstUntimed
            setDraft(current, dirty: false)
        }
        finishTask?.cancel()
        fixLineReturnTask?.cancel()
        undoSeekTask?.cancel()
        fixLine = nil
        lineSelectMode = false
        phase = .preview
        rebuildPreview()
        let offset = offsetMs
        let snapshot = current
        previewSeekTask?.cancel()
        previewSeekTask = Task { [weak self] in
            let target = await Task.detached(priority: .userInitiated) {
                Self.previewStartMs(snapshot, offsetMs: offset, focusLine: focusLine)
            }.value
            guard !Task.isCancelled, let self, self.phase == .preview else { return }
            self.seekTo(max(0, target))
            self.play()
        }
    }

    nonisolated private static func previewStartMs(_ current: SyncDraft, offsetMs: Int, focusLine: Int?) -> Int64 {
        guard let timing = LyricsTapSync.resolveTiming(current, offsetMs: offsetMs) else { return 0 }
        if let focusLine, current.lines.indices.contains(focusLine) {
            return timing.startsMs[current.lines[focusLine].firstToken] - previewLinePrerollMs
        }
        return (timing.startsMs.min() ?? 0) - previewStartPrerollMs
    }

    private func rebuildPreview() {
        guard let current = draft else { return }
        let offset = offsetMs
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { Self.buildPreview(current, offsetMs: offset) }.value
            guard !Task.isCancelled, let self else { return }
            if self.draft == current || self.draft?.tokens == current.tokens { self.preview = built }
        }
    }

    /// Earlier / later: moves every word by `steps` × 20 ms, no seek.
    func nudge(_ steps: Int) {
        guard let current = draft else { return }
        let next = LyricsTapSync.setNudge(current, nudgeMs: current.nudgeMs + steps * LyricsTapSync.nudgeStepMs)
        if next.nudgeMs == current.nudgeMs { return }
        setDraft(next, dirty: true)
        rebuildPreview()
    }

    func setLineSelectMode(_ enabled: Bool) { lineSelectMode = enabled }

    /// A tap on a preview line: jump to it, or re-tap it when picking the line that's off.
    func onPreviewLineTap(preparedIndex: Int, lineStartMs: Int64) {
        guard lineSelectMode else {
            seekTo(max(0, lineStartMs - Self.previewLinePrerollMs))
            return
        }
        guard let map = preview?.draftLineForPrepared, map.indices.contains(preparedIndex) else { return }
        startFixLine(map[preparedIndex])
    }

    private func startFixLine(_ lineIndex: Int) {
        guard let current = draft else { return }
        let step = LyricsTapSync.fixLine(current, lineIndex: lineIndex, speed: speed, offsetMs: offsetMs)
        if step.draft == current && step.seekToMs == nil { return }
        setDraft(step.draft, dirty: true)
        fixLine = lineIndex
        lineSelectMode = false
        preview = nil
        started = true
        phase = .fixLine(lineIndex)
        if let seek = step.seekToMs { seekTo(seek) }
        play()
    }

    /// "Keep tapping": back to the tap screen at the cursor.
    func keepTapping() {
        guard let current = draft else { return }
        beginTapping(current, resume: true)
    }

    func save() {
        guard let song, let current = draft, !isSaving else { return }
        isSaving = true
        pause()
        let offset = offsetMs
        let service = lyricsController.syncService
        let isUITest = self.isUITest
        Task { [weak self] in
            // Built and serialised off the main thread: the JSON is tens of KB.
            let encoded = await Task.detached(priority: .userInitiated) { () -> String? in
                guard case .success(let result) = LyricsTapSync.buildResult(current, offsetMs: offset) else { return nil }
                return LyricsDocCodec.encode(result.doc)
            }.value
            var ok = false
            if let encoded {
                if let service {
                    ok = await service.save(song: song, rawContent: encoded, source: LyricsTapSync.sourceUser) != nil
                } else {
                    ok = isUITest
                }
            }
            guard let self, self.sessionOpen, self.songId == song.id else { return }
            if !ok {
                self.flushDraft()
                self.isSaving = false
                self.dialog = .saveFailed
                return
            }
            if current.nudgeMs != 0 {
                let learned = LyricsTapSync.learnedOffsetMs(currentOffsetMs: offset, nudgeMs: current.nudgeMs)
                if self.bluetooth { self.settings.lyrics.tapOffsetBluetoothMs = learned }
                else { self.settings.lyrics.tapOffsetSpeakerMs = learned }
            }
            self.deleteDraftFile()
            self.saved = true
            self.close()
            if service != nil { self.lyricsController.load(song, forceRefresh: false) }
            self.lyricsController.message = SyncStrings.saved
        }
    }

    /// The finished file for "Share lyrics file", or nil while nothing is tapped.
    func exportText(ttml: Bool) async -> String? {
        guard let current = draft else { return nil }
        let offset = offsetMs
        return await Task.detached(priority: .userInitiated) { () -> String? in
            guard case .success(let doc) = LyricsTapSync.toLyricsDoc(current, offsetMs: offset) else { return nil }
            return ttml ? LyricsExport.toTtml(doc) : LyricsExport.toEnhancedLrc(doc)
        }.value
    }

    /// A file name for the exported lyrics: "Artist - Title".
    func exportFileName(ttml: Bool) -> String {
        Self.exportFileName(artist: artist, title: title, ttml: ttml)
    }

    nonisolated static func exportFileName(artist: String, title: String, ttml: Bool) -> String {
        let joined = [artist, title].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " - ")
        let forbidden = Set("\\/:*?\"<>|")
        var base = String(joined.map { forbidden.contains($0) ? "_" : $0 })
        if base.trimmingCharacters(in: .whitespaces).isEmpty { base = "lyrics" }
        return base + (ttml ? ".ttml" : ".lrc")
    }

    // MARK: - Notices

    private func showNotice(_ kind: SyncNoticeKind, count: Int = 0, canUndo: Bool = false) {
        noticeCounter += 1
        notice = SyncNotice(id: noticeCounter, kind: kind, count: count, canUndo: canUndo)
    }

    func dismissNotice(id: Int? = nil) {
        if id != nil && holdsDemoNotice { return }
        if id == nil || notice?.id == id { notice = nil }
    }

    // MARK: - Helpers

    private func setDraft(_ next: SyncDraft, dirty markDirty: Bool) {
        if draft != next { draft = next }
        guard sessionOpen, markDirty else { return }
        dirty = true
        scheduleDraftSave()
    }

    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.draftSaveDelayMs))
            guard !Task.isCancelled, let self, let current = self.draft, current.tappedCount > 0, !self.saved,
                  self.sessionOpen else { return }
            _ = await self.draftStore.save(current)
        }
    }

    private func flushDraft() {
        guard sessionOpen, let current = draft, dirty, !saved, current.tappedCount > 0 else { return }
        draftSaveTask?.cancel()
        let store = draftStore
        Task.detached(priority: .utility) { _ = await store.save(current) }
    }

    private func deleteDraftFile() {
        let store = draftStore, id = songId
        Task.detached(priority: .utility) { await store.delete(id) }
    }

    private func lastStampedStart(_ d: SyncDraft) -> Int64? {
        var i = min(d.cursor, d.tokens.count) - 1
        while i >= 0 {
            if let start = LyricsTapSync.builtStartMs(d, i, offsetMs: offsetMs) { return start }
            i -= 1
        }
        return nil
    }

    private func scaled(_ ms: Int64) -> Int64 { Int64(Double(ms) * Double(speed)) }

    private func play() {
        player.play()
        isPlaying = true
    }

    private func pause() {
        player.pause()
        isPlaying = false
    }

    private func seekTo(_ ms: Int64) { player.seek(toMs: max(0, ms)) }

    nonisolated static func uptimeMs(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

    // MARK: - Pure helpers (Android companion object)

    /// The words of any lyrics as plain text, one line per line (romanisation dropped).
    nonisolated static func plainText(of lyrics: Lyrics?) -> String {
        guard let lyrics else { return "" }
        if let lines = lyrics.document?.lines, !lines.isEmpty {
            return lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }
        if let synced = lyrics.synced, !synced.isEmpty {
            return synced.map { $0.line.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return (lyrics.plain ?? [])
            .map { line in
                let first = line.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                return first.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The preview document: the real result, with "≈" appended to roughly timed lines.
    nonisolated static func buildPreview(_ draft: SyncDraft, offsetMs: Int) -> SyncPreview? {
        guard case .success(let result) = LyricsTapSync.buildResult(draft, offsetMs: offsetMs),
              let timing = LyricsTapSync.resolveTiming(draft, offsetMs: offsetMs) else { return nil }
        // Same ordering as buildResult: lines with words, stably sorted by first start.
        let order = draft.lines.indices
            .filter { draft.lines[$0].tokenCount > 0 }
            .enumerated()
            .sorted { a, b in
                let sa = timing.startsMs[draft.lines[a.element].firstToken]
                let sb = timing.startsMs[draft.lines[b.element].firstToken]
                return sa != sb ? sa < sb : a.offset < b.offset
            }
            .map(\.element)
        let doc = result.roughLineIndices.isEmpty ? result.doc : markRough(result.doc, rough: result.roughLineIndices)
        guard let prepared = PreparedLyricsBuilder.build(doc) else { return nil }
        let map: [Int]
        if prepared.lines.count == order.count {
            map = order
        } else {
            map = prepared.lines.map { line in
                order.first { timing.startsMs[draft.lines[$0].firstToken] == line.startMs } ?? 0
            }
        }
        return SyncPreview(prepared: prepared, draftLineForPrepared: map, hasRoughLines: !result.roughLineIndices.isEmpty)
    }

    nonisolated private static func markRough(_ doc: LyricsDoc, rough: Set<Int>) -> LyricsDoc {
        var marked = doc
        for index in marked.lines.indices where rough.contains(index) && !marked.lines[index].syllables.isEmpty {
            marked.lines[index].text += roughMark
            let last = marked.lines[index].syllables.count - 1
            marked.lines[index].syllables[last].text += roughMark
        }
        return marked
    }
}

/// The editor's own preferences: how often the intro was seen (`lyrics_sync_intro_seen_count`). UI tests keep it in
/// memory, so every launch starts from the intro.
@MainActor
final class LyricsSyncPreferences {
    private let defaults: UserDefaults?
    private var memory = 0

    init(isUITest: Bool) {
        defaults = isUITest ? nil : .standard
    }

    var introSeenCount: Int {
        get { defaults?.integer(forKey: PreferenceKeys.lyricsSyncIntroSeenCount) ?? memory }
        set {
            if let defaults { defaults.set(newValue, forKey: PreferenceKeys.lyricsSyncIntroSeenCount) } else { memory = newValue }
        }
    }
}

// MARK: - UI-test states

extension LyricsSyncSession {
    /// Puts the editor straight into a screen state for the screenshot tests (`-syncStep`): no loading, a fixed
    /// position, the demo song kept as is. Lives here because it sets the observable state directly.
    func applyDemo(_ state: LyricsSyncDemoState) {
        guard let song = player.currentSong else { return }
        self.song = song
        songId = song.id
        title = song.title
        artist = song.displayArtist
        sessionOpen = true
        previousSpeed = 1
        player.beginSession()
        frozenPositionMs = state.positionMs
        draft = state.draft
        origin = state.origin
        wordsSeed = state.wordsSeed
        speed = state.speed
        isPlaying = state.isPlaying
        started = state.isPlaying || state.started
        sessionTaps = state.sessionTaps
        lineSelectMode = state.lineSelectMode
        if case .fixLine(let line) = state.phase { fixLine = line } else { fixLine = nil }
        notice = state.notice
        holdsDemoNotice = state.notice != nil
        dialog = state.dialog
        endedEarlyWords = state.draft?.remainingCount ?? 0
        dirty = state.draft.map { $0.tappedCount > 0 } ?? false
        if state.isPlaying { player.play() } else { player.pause() }
        if case .preview = state.phase, let draft = state.draft {
            preview = Self.buildPreview(draft, offsetMs: offsetMs)
        }
        phase = state.phase
    }
}
