// The random tap-sync sessions of the Android property test
// (`LyricsTapSyncTest.toLyricsDoc_isAlwaysValidForRandomSessions`), generated with the same Kotlin `Random(seed)`
// draws in the same order, so seed N here is seed N on Android. Shared by the property test and the golden test.

import PixlFoundation
import PixlModel
@testable import PixlLyrics

enum RandomSessions {

    static let wordPool = [
        "love", "you", "twenty-one", "rock'n'roll", "(oh", "yeah,", "—", "&", "…", "君が", "好き", "ラーメン",
        "きょう", "「愛」", "사랑해", "👨‍👩‍👧", "❤️", "OK。", "a",
        "night-time", "don't", String(repeating: "x", count: 45),
    ]

    static func randomText(_ random: inout KotlinRandom) -> String {
        let count = random.nextInt(1, 9)
        var words: [String] = []
        for _ in 0..<count { words.append(random.pick(wordPool)) }
        return words.joined(separator: " ")
    }

    static func kotlinInt(_ value: Int64) -> Int { Int(Int32(truncatingIfNeeded: value)) }

    static func randomDraft(_ random: inout KotlinRandom) -> SyncDraft {
        let duration = random.pick([0, 500, 20_000, 60_000, 240_000] as [Int64])
        let textCount = random.nextInt(1, 12)
        var texts: [String] = []
        for _ in 0..<textCount { texts.append(randomText(&random)) }
        let roles = ["lead", "background", "duet"]
        var time = random.nextLong(0, 8_000)
        var lyrics: Lyrics?
        var paste: String?
        switch random.nextInt(4) {
        case 0:
            paste = texts.joined(separator: "\n")
        case 1:
            var synced: [SyncedLine] = []
            for text in texts {
                time += random.nextLong(500, 9_000)
                let translation: String? = random.nextBoolean() ? "tr" : nil
                let role = random.pick(roles)
                synced.append(SyncedLine(time: kotlinInt(time), line: text, translation: translation, voiceRole: role))
            }
            lyrics = Lyrics(synced: synced)
        case 2:
            var synced: [SyncedLine] = []
            for text in texts {
                time += random.nextLong(500, 6_000)
                let lineStart = time
                let tokens = LyricsTapSync.tokenize(text)
                var words: [SyncedWord]?
                if random.nextInt(5) != 0 {
                    var out: [SyncedWord] = []
                    for (k, token) in tokens.enumerated() {
                        time += random.nextLong(0, 700)
                        let startsNew = k == 0 || tokens[k - 1].hasSuffix(" ")
                        let end: Int? = random.nextBoolean() ? kotlinInt(time + random.nextLong(-100, 900)) : nil
                        out.append(SyncedWord(time: kotlinInt(time), word: token.kotlinTrimmed(), startsNewWord: startsNew,
                                              endTime: end))
                    }
                    words = out
                }
                let role = random.pick(roles)
                synced.append(SyncedLine(time: kotlinInt(lineStart), line: text, words: words, voiceRole: role))
            }
            lyrics = Lyrics(synced: synced)
        default:
            let voices = [Voice(id: "lead", role: "lead"), Voice(id: "bg", role: "background"), Voice(id: "v2", role: "duet")]
            var lines: [TimedLine] = []
            for text in texts {
                time += random.nextLong(300, 6_000)
                let lineStart = time
                let tokens = LyricsTapSync.tokenize(text)
                var syllables: [TimedSyllable] = []
                if random.nextInt(4) != 0 {
                    for token in tokens {
                        let s = time
                        let length = random.nextLong(1, 800)
                        time += random.nextLong(0, 700)
                        syllables.append(TimedSyllable(startMs: s, durationMs: length, text: token))
                    }
                }
                let end = max(lineStart + 1, syllables.map { $0.startMs + $0.durationMs }.max() ?? (lineStart + 2_000))
                let voiceId = random.pick(voices).id
                lines.append(TimedLine(startMs: lineStart, endMs: end, text: tokens.joined(), voiceId: voiceId,
                                       syllables: syllables))
            }
            let source: String? = random.nextBoolean() ? "user" : nil
            lyrics = Lyrics(document: LyricsDoc(metadata: LyricsMetadata(source: source), voices: voices, lines: lines))
        }
        return LyricsTapSync.buildDraft(songId: "seed", title: "T", artist: "A", album: "Al", durationMs: duration,
                                        lyrics: lyrics, pasted: paste).draft!
    }

    /// One reducer application of a session.
    struct Event {
        /// "init", the step number, or "final".
        var label: String
        /// The `nextInt(100)` action draw (-1 for init/final).
        var action: Int
        var before: SyncDraft
        var after: SyncDraft
        /// The reducer result, for reducers that return a `SyncStep`.
        var step: SyncStep?
    }

    /// Runs seed `seed` and reports the initial draft, every step and the finished (tapped-out) draft.
    /// Returns the number of random actions and the reaction offset.
    @discardableResult
    static func run(seed: Int32, _ visit: (Event, _ offset: Int) -> Void) -> (actions: Int, offset: Int) {
        var random = KotlinRandom(seed: seed)
        let offset = Int(random.nextInt(0, 401))
        var draft = randomDraft(&random)
        var position = random.nextLong(0, 5_000)
        let actions = Int(random.nextInt(1, 120))
        visit(Event(label: "init", action: -1, before: draft, after: draft, step: nil), offset)
        for stepIndex in 0..<actions {
            position = max(0, position + random.nextLong(-400, 2_000))
            let speed = random.pick([0.5, 0.75, 1] as [Float])
            let scope: Int? = random.nextInt(8) == 0 ? draft.currentLineIndex : nil
            let action = Int(random.nextInt(100))
            let before = draft
            var step: SyncStep?
            switch action {
            case 0...59:
                step = LyricsTapSync.tap(draft, rawStartMs: position, speed: speed, offsetMs: offset, scopeLine: scope)
            case 60...64:
                let last = stride(from: draft.cursor - 1, through: 0, by: -1).first {
                    $0 < draft.tokens.count && draft.tokens[$0].rawStartMs != nil
                }
                if let last {
                    draft = LyricsTapSync.release(draft, tokenIndex: last, rawEndMs: position + random.nextLong(0, 3_000),
                                                  speed: speed, offsetMs: offset)
                }
            case 65...71:
                step = LyricsTapSync.undo(draft, speed: speed, offsetMs: offset, scopeLine: scope)
            case 72...76:
                step = LyricsTapSync.rewind(draft, positionMs: position, offsetMs: offset, scopeLine: scope)
            case 77...80:
                step = LyricsTapSync.jumpToLine(draft, lineIndex: Int(random.nextInt(Int32(draft.lines.count))),
                                                speed: speed, offsetMs: offset)
            case 81...83:
                step = LyricsTapSync.fixLine(draft, lineIndex: Int(random.nextInt(Int32(draft.lines.count))),
                                             speed: speed, offsetMs: offset)
            case 84...87:
                step = LyricsTapSync.skipLine(draft, offsetMs: offset)
            case 88...89:
                step = LyricsTapSync.fillRest(draft, offsetMs: offset)
            case 90...96:
                draft = LyricsTapSync.setNudge(draft, nudgeMs: Int(random.nextInt(-500, 501)))
            default:
                if random.nextInt(4) == 0 { draft = LyricsTapSync.clearAll(draft) }
            }
            if let step { draft = step.draft }
            visit(Event(label: String(stepIndex), action: action, before: before, after: draft, step: step), offset)
        }
        let stepMs = random.nextLong(1, 900)
        let done = tapAll(draft, startMs: position, stepMs: stepMs, offsetMs: offset)
        visit(Event(label: "final", action: -1, before: draft, after: done, step: nil), offset)
        return (actions, offset)
    }

    static func tapAll(_ draft: SyncDraft, startMs: Int64 = 1_000, stepMs: Int64 = 400, speed: Float = 1,
                       offsetMs: Int = 0) -> SyncDraft {
        var d = draft
        var t = startMs
        while !d.isFinished {
            d = LyricsTapSync.tap(d, rawStartMs: t, speed: speed, offsetMs: offsetMs).draft
            t += stepMs
        }
        return d
    }
}
