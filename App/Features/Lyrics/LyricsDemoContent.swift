import CoreGraphics
import Foundation
import PixlModel

/// Lyrics launch arguments for UI and screenshot tests (only read with `-uiTest`):
///
///     -lyricsDemo words|duet|lines|plain|none   which demo lyrics the current song gets (default words)
///     -lyricsFreezeMs <ms>                      freeze the lyrics clock at this song position (no drift, no motion)
///     -lyricsBrightArt                          use a pale artwork (bright-art blending and scrim)
///     -lyricsHighContrast                       force the increased-contrast look
///     -lyricsImmersive                          start with the controls hidden (immersive mode)
nonisolated struct LyricsLaunchOptions: Sendable, Equatable {
    var demo: LyricsDemoContent.Variant
    var freezeMs: Int64?
    var brightArt: Bool
    var highContrast: Bool
    var immersive: Bool

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        demo = value(after: "-lyricsDemo").flatMap(LyricsDemoContent.Variant.init(rawValue:)) ?? .words
        freezeMs = value(after: "-lyricsFreezeMs").flatMap(Int64.init)
        brightArt = arguments.contains("-lyricsBrightArt")
        highContrast = arguments.contains("-lyricsHighContrast")
        immersive = arguments.contains("-lyricsImmersive")
    }

    static let current = LyricsLaunchOptions(arguments: ProcessInfo.processInfo.arguments)
}

/// Deterministic demo lyrics for the UI tests: word-synced lines with explicit word ends (so long words get the
/// emphasis glow), a long instrumental gap (interlude dots), a duet with background vocals, line-synced and plain
/// variants. The screenshot tests freeze the clock at the times below.
nonisolated enum LyricsDemoContent {
    enum Variant: String, Sendable, CaseIterable {
        case words, duet, lines, plain, none
    }

    /// Mid-line word fill: 1.3 s into line 10 ("Paper lanterns drifting over the bay").
    static let midLineMs: Int64 = 42_300
    /// Peak of the emphasis on "higher" (word starts 45 760, effective duration 2 880 ms as the last word).
    static let emphasisPeakMs: Int64 = 47_600
    /// Inside the instrumental gap 56 000 … 67 000 (breathing dots).
    static let interludeMs: Int64 = 61_000

    private static let verses: [String] = [
        "Under the glow of a paper moon",
        "We traced our names in the morning dew",
        "Every street was singing back to us",
        "Every window held a different blue",
        "Carry the night in a folded hand",
        "Over the rooftops and into the sand",
        "Nobody told us the colours would stay",
        "Running in circles to find our way",
        "Count every heartbeat and let it go",
        "Follow the river wherever it flows",
        "Paper lanterns drifting over the bay",
    ]

    private static let after: [String] = [
        "Light up the harbour and call my name",
        "Nothing between us will be the same",
        "Golden and gentle the morning came",
        "Hold me forever and fan the flame",
        "We were the echo inside the rain",
    ]

    static func lyrics(_ variant: Variant) -> Lyrics? {
        switch variant {
        case .none: return nil
        case .plain: return Lyrics(plain: plainLines, synced: nil)
        case .lines:
            let synced = wordSyncedLines(duet: false).map { line in
                SyncedLine(time: line.time, line: line.line, words: nil, translation: line.translation, endTime: nil,
                           voiceRole: line.voiceRole)
            }
            return Lyrics(plain: synced.map(\.line), synced: synced)
        case .words: return Lyrics(plain: nil, synced: wordSyncedLines(duet: false))
        case .duet: return Lyrics(plain: nil, synced: wordSyncedLines(duet: true))
        }
    }

    private static let wordMs = 380

    private static func line(_ text: String, at start: Int, role: String = "lead", longLast: Int? = nil,
                             translation: String? = nil) -> SyncedLine {
        let parts = text.split(separator: " ").map(String.init)
        var t = start
        var words: [SyncedWord] = []
        for (i, part) in parts.enumerated() {
            let duration = (i == parts.count - 1 ? longLast : nil) ?? wordMs
            words.append(SyncedWord(time: t, word: part, startsNewWord: true, endTime: t + duration))
            t += duration
        }
        return SyncedLine(time: start, line: text, words: words, translation: translation, endTime: t, voiceRole: role)
    }

    private static func wordSyncedLines(duet: Bool) -> [SyncedLine] {
        var lines: [SyncedLine] = []
        for (k, text) in verses.enumerated() {
            let role = duet && k % 2 == 1 ? "duet" : "lead"
            lines.append(line(text, at: 1_000 + 4_000 * k, role: role))
        }
        if duet {
            // Background vocals answering lines 9 and 10.
            lines.append(line("(let it go)", at: 38_400, role: "background"))
            lines.append(line("(over the bay)", at: 41_900, role: "background"))
        }
        lines.append(line("Take me higher", at: 45_000, role: duet ? "duet" : "lead", longLast: 2_400))
        lines.append(line("Say it again in the softest way", at: 49_000,
                          translation: duet ? nil : "Dilo otra vez de la forma más suave"))
        lines.append(line("Stay till the stars run out of light", at: 53_000, role: duet ? "duet" : "lead"))
        // Instrumental gap 56 000 … 67 000.
        for (k, text) in after.enumerated() {
            let role = duet && k % 2 == 1 ? "duet" : "lead"
            lines.append(line(text, at: 67_000 + 4_000 * k, role: role))
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static let plainLines: [String] = [
        "[Verse 1]",
        "Under the glow of a paper moon",
        "We traced our names in the morning dew",
        "Every street was singing back to us",
        "Every window held a different blue",
        "",
        "[Chorus]",
        "Take me higher",
        "Say it again in the softest way",
        "Stay till the stars run out of light",
        "",
        "[Verse 2]",
        "Light up the harbour and call my name",
        "Nothing between us will be the same",
        "Golden and gentle the morning came",
        "Hold me forever and fan the flame",
    ]
}

/// Demo artwork for the lyrics screenshots.
enum LyricsDemoArt {
    /// A pale, almost white cover: its graded luma is above 0.6, so the screen takes the bright-art path (normal
    /// blending, inactive alpha 0.50, 35 % scrim).
    static let bright: CGImage? = {
        let size = 96
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colors = [CGColor(srgbRed: 1, green: 0.97, blue: 0.9, alpha: 1),
                      CGColor(srgbRed: 0.93, green: 0.96, blue: 1, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.75, alpha: 1))
        context.fillEllipse(in: CGRect(x: 20, y: 24, width: 44, height: 44))
        return context.makeImage()
    }()
}
