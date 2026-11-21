// The spoken side of the host of Endless Listening (milestone E2), as pure rules: when a host note may be said aloud, what is said, how the
// music is ducked while it is, and when a line that has started must stop. The app only reads the world (the deck, the call state, the
// audio route) and hands the numbers over; this file and Android's `:brain` `HostVoice.kt` reproduce `hostvoice.jsonl` bit for bit.
//
// Principles, all of them a refusal rather than an effort: a line is said only at a calm moment, never over a transition, a phone call or a
// route change, and any doubt means silence. Every skip has a reason that the developer log shows.
//
// No clock and no locale here: time enters as milliseconds, text is taken apart by plain character tests (UTF-16 units, as the Kotlin does).

public enum HostVoice {
    /// A line starts at least this long into the track (the track must have settled, the previous song's tail is gone).
    public static let minIntoTrackMs: Int64 = 1_500

    /// After the audio route changed (headphones, Bluetooth) nothing is said for this long.
    public static let routeQuietMs: Int64 = 4_000

    /// At least this many other songs start between two spoken lines. A note is already at most one per five tracks.
    public static let minTracksBetween = 4

    /// A line may still start this long after its track began; later it is dropped (it would describe a song already half over).
    public static let windowMs: Int64 = 15_000

    /// The music is brought down over this long, and up again over the next. The quick way back is for a skip or a pause.
    public static let rampDownMs: Int64 = 250
    public static let rampUpMs: Int64 = 400
    public static let rampUpQuickMs: Int64 = 120

    /// The level the music is held at while the host speaks, in thousandths of the level it had.
    public static let duckPermille = 350

    /// The level the music has when nothing is held down.
    public static let permilleFull = 1_000

    /// No line is allowed to run longer than this; the voice is stopped and the music comes back.
    public static let maxSpeechMs: Int64 = 8_000

    /// The song must still have this much left after the line, so the next transition never starts under the host's voice.
    public static let transitionMarginMs: Int64 = 15_000

    /// A rough length of a spoken line: `msPerWord` a word and a breath at the start.
    public static let msPerWord: Int64 = 420
    public static let leadMs: Int64 = 600

    /// The developer log keeps this many decisions.
    public static let logSize = 20

    /// What `Decision.action` says.
    public static let actSpeak = 0
    public static let actWait = 1
    public static let actSkip = 2

    /// The state of the system voice.
    public static let voiceNone = 0
    public static let voicePending = 1
    public static let voiceReady = 2

    /// `tracksSinceLast` when nothing was spoken yet.
    public static let never = 1_000_000

    /// A line is at most this many UTF-16 units long.
    public static let maxChars = 160

    private static let minWaitMs: Int64 = 50

    /// Everything the decision looks at, read at one moment. `line` is the cleaned text of the note of the current song ("" when it has
    /// none); `sameAsLast` says it is the line already spoken for this song or the one before; `tracksSinceLast` is how many other songs
    /// started since the last spoken line; `sinceStartMs` how long ago the current song started (measured by the caller); `currentIsTarget`
    /// says the engine's deck already plays the song the note belongs to (a transition shows the new song early); `positionMs` and
    /// `remainingMs` are the playing deck's, `remainingMs` negative when the length is unknown; `msSinceRoute` how long ago the audio route
    /// last changed.
    public struct Inputs: Sendable, Equatable {
        public var enabled: Bool
        public var endless: Bool
        public var notesOn: Bool
        public var line: String
        public var sameAsLast: Bool
        public var tracksSinceLast: Int
        public var sinceStartMs: Int64
        public var currentIsTarget: Bool
        public var transitionRunning: Bool
        public var playing: Bool
        public var inCall: Bool
        public var msSinceRoute: Int64
        public var positionMs: Int64
        public var remainingMs: Int64
        public var voice: Int
        public var canDuck: Bool

        public init(enabled: Bool, endless: Bool, notesOn: Bool, line: String, sameAsLast: Bool, tracksSinceLast: Int,
                    sinceStartMs: Int64, currentIsTarget: Bool, transitionRunning: Bool, playing: Bool, inCall: Bool,
                    msSinceRoute: Int64, positionMs: Int64, remainingMs: Int64, voice: Int, canDuck: Bool) {
            self.enabled = enabled
            self.endless = endless
            self.notesOn = notesOn
            self.line = line
            self.sameAsLast = sameAsLast
            self.tracksSinceLast = tracksSinceLast
            self.sinceStartMs = sinceStartMs
            self.currentIsTarget = currentIsTarget
            self.transitionRunning = transitionRunning
            self.playing = playing
            self.inCall = inCall
            self.msSinceRoute = msSinceRoute
            self.positionMs = positionMs
            self.remainingMs = remainingMs
            self.voice = voice
            self.canDuck = canDuck
        }
    }

    /// `action`: say it now, ask again after `waitMs`, or give up on this note for good. `reason` is a short stable word for the log.
    public struct Decision: Sendable, Equatable {
        public let action: Int
        public let reason: String
        public let waitMs: Int64

        public init(action: Int, reason: String, waitMs: Int64) {
            self.action = action
            self.reason = reason
            self.waitMs = waitMs
        }
    }

    private static func skip(_ reason: String) -> Decision { Decision(action: actSkip, reason: reason, waitMs: 0) }

    private static func hold(_ reason: String, _ ms: Int64) -> Decision {
        Decision(action: actWait, reason: reason, waitMs: ms < minWaitMs ? minWaitMs : ms)
    }

    /// The decision for one moment. Never traps. The order is the order of the reasons: the first one that holds ends it.
    public static func decide(_ i: Inputs) -> Decision {
        if !i.enabled { return skip("off") }
        if !i.endless { return skip("not_endless") }
        if !i.notesOn { return skip("notes_off") }
        if i.line.isEmpty { return skip("no_line") }
        if i.sameAsLast { return skip("repeat") }
        if i.tracksSinceLast < minTracksBetween { return skip("too_soon") }
        if i.inCall { return skip("call") }
        if !i.playing { return skip("paused") }
        if i.msSinceRoute < routeQuietMs { return skip("route_changed") }
        if i.sinceStartMs > windowMs { return skip("window_over") }
        if i.transitionRunning { return hold("transition", 300) }
        if !i.currentIsTarget { return hold("not_current", 300) }
        if i.positionMs < minIntoTrackMs { return hold("too_early", minIntoTrackMs - i.positionMs) }
        if i.remainingMs < 0 { return skip("unknown_length") }
        if i.remainingMs < estimateMs(i.line) + transitionMarginMs { return skip("short_left") }
        if i.voice == voiceNone { return skip("no_voice") }
        if i.voice == voicePending { return hold("voice_pending", 300) }
        if !i.canDuck { return skip("cant_duck") }
        return Decision(action: actSpeak, reason: "speak", waitMs: 0)
    }

    /// What the app sees while a line is running. `sinceSpeechStartMs` counts from the first word.
    public struct Running: Sendable, Equatable {
        public var enabled: Bool
        public var endless: Bool
        public var notesOn: Bool
        public var songChanged: Bool
        public var playing: Bool
        public var transitionRunning: Bool
        public var focusLost: Bool
        public var inCall: Bool
        public var routeChanged: Bool
        public var volumeTaken: Bool
        public var sinceSpeechStartMs: Int64

        public init(enabled: Bool, endless: Bool, notesOn: Bool, songChanged: Bool, playing: Bool, transitionRunning: Bool,
                    focusLost: Bool, inCall: Bool, routeChanged: Bool, volumeTaken: Bool, sinceSpeechStartMs: Int64) {
            self.enabled = enabled
            self.endless = endless
            self.notesOn = notesOn
            self.songChanged = songChanged
            self.playing = playing
            self.transitionRunning = transitionRunning
            self.focusLost = focusLost
            self.inCall = inCall
            self.routeChanged = routeChanged
            self.volumeTaken = volumeTaken
            self.sinceSpeechStartMs = sinceSpeechStartMs
        }
    }

    /// "" while the line may go on, else why it must stop at once (the first reason that holds).
    public static func cancelReason(_ r: Running) -> String {
        if !r.enabled { return "off" }
        if !r.notesOn { return "notes_off" }
        if !r.endless { return "not_endless" }
        if r.songChanged { return "skip" }
        if !r.playing { return "pause" }
        if r.transitionRunning { return "transition" }
        if r.focusLost { return "focus" }
        if r.inCall { return "call" }
        if r.routeChanged { return "route" }
        if r.volumeTaken { return "volume_taken" }
        if r.sinceSpeechStartMs > maxSpeechMs { return "too_long" }
        return ""
    }

    /// Roughly how long `line` takes to say.
    public static func estimateMs(_ line: String) -> Int64 { Int64(HostNotes.wordCount(line)) * msPerWord + leadMs }

    /// A linear ramp in thousandths: from `fromPermille` to `toPermille` over `rampMs`, `elapsedMs` in. The ends are exact (no rounding
    /// drift), a ramp of no length is at its end at once.
    public static func ramp(_ fromPermille: Int, _ toPermille: Int, elapsedMs: Int64, rampMs: Int64) -> Int {
        if rampMs <= 0 || elapsedMs >= rampMs { return toPermille }
        if elapsedMs <= 0 { return fromPermille }
        // Int64 maths, truncating toward zero as the Kotlin does.
        return fromPermille + Int((Int64(toPermille - fromPermille) * elapsedMs) / rampMs)
    }

    /// The line the host says for a note's `text`, or "" when the note must stay on the screen only: at most `maxChars` characters, two
    /// sentences of at most `HostNotes.maxWords` words, none of the words the app never says; marks a voice reads badly are taken out
    /// ("&" is said "and"). Text is never cut: a note that is too long is not said at all. `noteChecked` is true for the text of a note the
    /// app made itself (`HostNotes` looked for the banned words in what the app wrote and not in a name, so "Claude Debussy" stays): only
    /// its length is checked here.
    public static func line(_ text: String, noteChecked: Bool = false) -> String {
        var sb: [UInt16] = []
        sb.reserveCapacity(text.utf16.count + 8)
        var lastSpace = true
        let space: UInt16 = 0x20
        let andWord: [UInt16] = [0x20, 0x61, 0x6E, 0x64, 0x20]
        for c in text.utf16 {
            switch c {
            case 0x26: // &
                for o in andWord { push(o, &sb, &lastSpace) }
            case 0x22, 0x2A, 0x5F, 0x7E, 0x7C, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x5C, 0x23, 0xB7, 0x2022, 0x0A, 0x0D, 0x09:
                push(space, &sb, &lastSpace)
            default:
                push(c, &sb, &lastSpace)
            }
        }
        if sb.last == space { sb.removeLast() }
        if sb.isEmpty || sb.count > maxChars { return "" }
        let s = String(decoding: sb, as: UTF16.self)
        return (noteChecked ? HostNotes.isShort(s) : HostNotes.isSpeakable(s)) ? s : ""
    }

    private static func push(_ o: UInt16, _ sb: inout [UInt16], _ lastSpace: inout Bool) {
        if o == 0x20 {
            if lastSpace { return }
            lastSpace = true
        } else {
            // A mark taken out must not leave a gap before the full stop or comma that follows it.
            if (o == 0x2E || o == 0x2C || o == 0x21 || o == 0x3F || o == 0x3A || o == 0x3B), sb.last == 0x20 {
                sb.removeLast()
            }
            lastSpace = false
        }
        sb.append(o)
    }
}
