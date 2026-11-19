import Foundation
import Testing
@testable import PixlLibrary

/// The words of this milestone (docs/brain-spec.md, section 8 "Copy rule", decision D15): the words the app never
/// says, nothing that claims learning except where stage 3 allows it, and the copy of section 8 as the listener reads it.
/// The app's sources are read as text: nothing under `App/` compiles on this machine.
@Suite("Brain copy")
struct BrainCopyTests {
    private let forbidden = ["lossless", "hi-res", "hires", "dolby", "atmos", "360 reality", "claude", "anthropic",
                             "binilyrics", "enhanced"]

    /// Decision D15, as stage 3 relaxes it: "learn" may appear only in the strings the spec names for Your sound (8.6), each of
    /// which the screen shows only when it is true of the model at that moment (`ModelVoice`): the one line that says the
    /// model is learning, and the reset button and its question. Every other string still fails on it. The text is the
    /// literal as written in the source, interpolation included.
    private let learnAllowed: Set<String> = ["Learning from \\(count) plays.", "Reset what I've learned", "Reset what I've learned?"]

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App", isDirectory: true)
    }

    /// Every string literal of a Swift source, comments left out.
    private func literals(_ source: String) -> [String] {
        let chars = Array(source.unicodeScalars)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar = i + 1 < chars.count ? chars[i + 1] : " "
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
            } else if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if c == "\"" {
                i += 1
                var text = String.UnicodeScalarView()
                while i < chars.count && chars[i] != "\"" {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        text.append(chars[i])
                        i += 1
                    }
                    text.append(chars[i])
                    i += 1
                }
                i += 1
                out.append(String(text))
            } else {
                i += 1
            }
        }
        return out
    }

    private func sources() throws -> [(name: String, text: String)] {
        let brain = appRoot.appendingPathComponent("Features/Brain", isDirectory: true)
        var files = try FileManager.default.contentsOfDirectory(atPath: brain.path).filter { $0.hasSuffix(".swift") }
            .map { brain.appendingPathComponent($0) }
        files.append(appRoot.appendingPathComponent("Features/Queue/AutoplayLine.swift"))
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func noBrainStringUsesAWordTheAppNeverSays() throws {
        let files = try sources()
        #expect(files.count >= 5, "expected the brain's screens under \(appRoot.path), found \(files.count) files")
        var count = 0
        for file in files {
            for literal in literals(file.text) {
                count += 1
                let lower = literal.lowercased()
                for word in forbidden {
                    #expect(!lower.contains(word), "\(file.name) says \"\(word)\": \(literal)")
                }
                if !learnAllowed.contains(literal) {
                    #expect(!lower.contains("learn"), "\(file.name) says \"learn\": \(literal)")
                }
            }
        }
        #expect(count >= 40, "expected the brain's strings, found \(count)")
    }

    @Test func theWordLearnIsOnlyWhereTheSpecNamesIt() throws {
        let strings = try String(contentsOf: appRoot.appendingPathComponent("Features/Brain/BrainStringsSound.swift"), encoding: .utf8)
        let all = literals(strings)
        // The allowance is not a loophole: the three strings are really there, each exactly once, and they are the only
        // literals of the brain's screens that say "learn".
        for text in learnAllowed { #expect(all.filter { $0 == text }.count == 1, "missing: \(text)") }
        var said: [String] = []
        for file in try sources() {
            for literal in literals(file.text) where literal.lowercased().contains("learn") { said.append(literal) }
        }
        #expect(Set(said) == learnAllowed, "the strings that say learn: \(said)")
        // A sentence that says it fails the test unless it is one of the three.
        #expect(!learnAllowed.contains("The app learns what you like."))
        #expect(!learnAllowed.contains("Learning your taste"))
    }

    @Test func theCopyOfSectionEightIsWhatTheListenerReads() throws {
        let strings = try String(contentsOf: appRoot.appendingPathComponent("Features/Brain/BrainStrings.swift"), encoding: .utf8)
        let all = Set(literals(strings))
        for text in [
            "Start station", "Station · \\(title)", "Familiar", "Blend", "Discover", "Not for me",
            "Got it. You won't hear this in mixes again.", "Less from \\(artist)", "Undo",
            "Fans of \\(name) also play this", "Because you liked \\(name)", "Because you listened to \\(name)",
            "More from \\(name)", "On repeat lately", "Why this song", "How picks work",
            "Picks are based on what you play.", "Music you don't have yet",
            "Nobody can pay to be in your picks", "Nothing is slipped into your playlists", "It stays on your phone",
            // Stage 2a keeps the other half: a song is in one mix a day (served log, 6.4), and says so (8.9).
            "A song is never in two mixes on the same day, and a new song you skipped three times stays away for 60 days.",
            // Daily Mix and Your Mix (8.2) and the Developer mode rows.
            "Save", "Saved", "Music engine", "Background music search",
        ] {
            #expect(all.contains(text), "missing: \(text)")
        }
        let line = try String(contentsOf: appRoot.appendingPathComponent("Features/Queue/AutoplayLine.swift"), encoding: .utf8)
        #expect(Set(literals(line)).isSuperset(of: ["Autoplay", "Taizo picks more after this", "From your library",
                                                    "Skipped three. Changing direction."]))
    }

    @Test func theScanReadsLiteralsAndSkipsComments() {
        let found = literals("let a = \"One \\(x) two\" // \"not this\"\n/* \"nor this\" */ let b = \"Three\"")
        #expect(found == ["One \\(x) two", "Three"])
    }
}
