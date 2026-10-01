import Foundation
import Testing
import PixlFoundation
import PixlModel
@testable import PixlLyrics

/// Reads the golden fixtures written by `tools/android-reference/EngineGen.java` and replays their inputs.
enum EngineFixture {
    static func lines(_ name: String) throws -> [Substring] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).filter { !$0.hasPrefix("//") }
    }

    /// Tab-separated fields, keeping empty ones.
    static func fields(_ line: Substring) -> [Substring] { line.split(separator: "\t", omittingEmptySubsequences: false) }

    static func float(_ hex: Substring) -> Float { Float(bitPattern: UInt32(hex, radix: 16)!) }

    /// The fixture text escapes: `\t`, `\n`, `\s`, `\\`, `\uXXXX`.
    static func unescape(_ s: Substring) -> String {
        var out = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { out.append(c); break }
            switch n {
            case "t": out.append("\t")
            case "n": out.append("\n")
            case "s": out.append(" ")
            case "\\": out.append("\\")
            case "-": out.append("-")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.unicodeScalars.append(h) } }
                out.append(Unicode.Scalar(UInt32(hex, radix: 16)!) ?? "\u{FFFD}")
            default:
                out.append(c)
                out.append(n)
            }
        }
        return String(out)
    }

    /// `-` = nil, else unescaped.
    static func nullable(_ s: Substring) -> String? { s == "-" ? nil : unescape(s) }

    static func field(_ f: [Substring], _ i: Int) -> Substring { i < f.count ? f[i] : "" }

    /// A lyrics definition block (`LYRICS … END`).
    struct LyricsDef {
        var plain: [String] = []
        var synced: [SyncedLine] = []
        var voices: [Voice]?
        var docLines: [TimedLine] = []
        var hasDoc = false
        var hasSynced = false
        var hasPlain = false

        /// Applies one line; returns true at `END`.
        mutating func apply(_ f: [Substring]) -> Bool {
            switch f[0] {
            case "SL":
                hasSynced = true
                synced.append(SyncedLine(time: Int(f[1])!, line: EngineFixture.unescape(EngineFixture.field(f, 4)),
                                         endTime: f[2] == "-" ? nil : Int(f[2])!,
                                         voiceRole: f[3] == "-" ? "lead" : EngineFixture.unescape(f[3])))
            case "SW":
                var line = synced.removeLast()
                var words = line.words ?? []
                words.append(SyncedWord(time: Int(f[1])!, word: EngineFixture.unescape(EngineFixture.field(f, 4)),
                                        startsNewWord: f[3] == "1", endTime: f[2] == "-" ? nil : Int(f[2])!))
                line.words = words
                synced.append(line)
            case "ST":
                synced[synced.count - 1].translation = EngineFixture.nullable(EngineFixture.field(f, 1))
            case "SR":
                synced[synced.count - 1].romanization = EngineFixture.nullable(EngineFixture.field(f, 1))
            case "PLAIN":
                hasPlain = true
                plain.append(EngineFixture.unescape(EngineFixture.field(f, 1)))
            case "DVDEFAULT":
                hasDoc = true
            case "DV":
                hasDoc = true
                voices = (voices ?? []) + [Voice(id: EngineFixture.unescape(f[1]), role: EngineFixture.unescape(EngineFixture.field(f, 2)))]
            case "DL":
                hasDoc = true
                docLines.append(TimedLine(startMs: Int64(f[1])!, endMs: Int64(f[2])!,
                                          text: EngineFixture.unescape(EngineFixture.field(f, 4)), voiceId: EngineFixture.unescape(f[3])))
            case "DS":
                docLines[docLines.count - 1].syllables.append(
                    TimedSyllable(startMs: Int64(f[1])!, durationMs: Int64(f[2])!, text: EngineFixture.unescape(EngineFixture.field(f, 3))))
            case "END":
                return true
            default:
                Issue.record("bad lyrics line \(f)")
            }
            return false
        }

        var lyrics: Lyrics {
            let sl: [SyncedLine]? = (hasSynced || (!hasDoc && !hasPlain)) ? synced : nil
            let doc: LyricsDoc? = hasDoc ? LyricsDoc(voices: voices ?? [Voice()], lines: docLines) : nil
            return Lyrics(plain: hasPlain ? plain : nil, synced: sl, document: doc)
        }
    }
}

/// Replays the engine scenario commands exactly like `EngineGen.runScenarioLine`.
final class EngineScenarioRunner {
    var frameNanos: Int64 = 1_000_000_000
    var playerNanos: Int64 = 0
    var offsetMs: Int64 = 0
    var stepNanos: Int64 = 16_000_000
    var engine = LyricsEngine()
    var defs: [String: EngineFixture.LyricsDef] = [:]
    /// Called after every dumped frame.
    var onDump: (EngineScenarioRunner) -> Void = { _ in }

    func newEngine() {
        frameNanos = 1_000_000_000
        playerNanos = 0
        offsetMs = 0
        stepNanos = 16_000_000
        engine = LyricsEngine()
    }

    func frame() {
        engine.step(frameNanos: frameNanos, positionMs: playerNanos / 1_000_000, offsetMs: offsetMs)
    }

    func run(_ f: [Substring]) {
        switch f[0] {
        case "NEWENGINE": newEngine()
        case "CONFIG":
            engine.setConfig(LyricsEngineConfig(density: Float(f[1])!, blurSupported: f[2] == "1", blurEnabled: f[3] == "1",
                                                blurStrength: Float(f[4])!, reducedMotion: f[5] == "1"))
        case "LYRICS-SET":
            engine.setLyrics(PreparedLyricsBuilder.build(defs[String(f[1])]!.lyrics), animateIn: f[2] == "1")
        case "VIEW": engine.setViewport(height: Float(f[1])!, anchor: Float(f[2])!)
        case "HEIGHTS": for r in 0..<engine.rowCount { engine.setRowHeight(r, Float(f[1])!) }
        case "HEIGHTLIST": for r in 1..<f.count { engine.setRowHeight(r - 1, Float(f[r])!) }
        case "HEIGHT": engine.setRowHeight(Int(f[1])!, Float(f[2])!)
        case "PLAY": engine.clock.isPlaying = f[1] == "1"
        case "POS": playerNanos = Int64(f[1])! * 1_000_000
        case "OFFSET": offsetMs = Int64(f[1])!
        case "STEPNS": stepNanos = Int64(f[1])!
        case "FRAME":
            frame()
            onDump(self)
        case "ADV":
            var left = Int64(f[1])! * 1_000_000
            let stride = Int(f[2])!
            var i = 0
            while left > 0 {
                let d = Swift.min(stepNanos, left)
                frameNanos += d
                if engine.clock.isPlaying { playerNanos += d }
                frame()
                i += 1
                left -= d
                if i % stride == 0 || left == 0 { onDump(self) }
            }
        case "GAP": frameNanos += Int64(f[1])! * 1_000_000
        case "REBASE": engine.clock.rebase()
        case "RESET": engine.clock.reset()
        case "MARKSEEK": engine.clock.markSeek()
        case "DRAGSTART": engine.onDragStart()
        case "DRAG": engine.onDrag(Float(f[1])!)
        case "DRAGEND": engine.onDragEnd(velocity: Float(f[1])!)
        case "TAP": engine.onLineTapped(Int(f[1])!)
        case "SCROLLBY": engine.scrollBy(Float(f[1])!)
        default: Issue.record("bad scenario line \(f)")
        }
    }
}
