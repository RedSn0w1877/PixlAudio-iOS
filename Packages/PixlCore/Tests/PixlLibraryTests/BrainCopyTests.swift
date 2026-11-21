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
    /// model is learning (once for one play, once for the rest), and the reset button and its question. Every other string still fails on it. The text is the
    /// literal as written in the source, interpolation included.
    private let learnAllowed: Set<String> = ["Learning from \\(count) play.", "Learning from \\(count) plays.", "Reset what I've learned",
                                             "Reset what I've learned?"]

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
        // The allowance is not a loophole: the four strings are really there, each exactly once, and they are the only
        // literals of the brain's screens that say "learn".
        for text in learnAllowed { #expect(all.filter { $0 == text }.count == 1, "missing: \(text)") }
        var said: [String] = []
        for file in try sources() {
            for literal in literals(file.text) where literal.lowercased().contains("learn") { said.append(literal) }
        }
        #expect(Set(said) == learnAllowed, "the strings that say learn: \(said)")
        // A sentence that says it fails the test unless it is one of the four.
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

    /// Stage 4 milestone 2: the words under Ask Taizo's answers, the factors of a pick, the weekly note and the switch of the optional jobs
    /// are Android's sentences (`strings_brain.xml`), and none of them says "learn" (the stage 3 allowance names four other strings).
    @Test func theWordsOfStageFourMilestoneTwoAreAndroidsAndSayNoLearn() throws {
        let strings = try String(contentsOf: appRoot.appendingPathComponent("Features/Brain/BrainStringsTaizo.swift"), encoding: .utf8)
        let all = literals(strings)
        for text in [
            "1 song", "\\(count) songs", "Play", "Save", "Saved", "Updating", "That did not work. Try again.",
            "I could not load songs like what you started from just now, so this mix may not follow it.",
            "Some of what you asked for could not be applied, because PixlAudio has no data on it yet.",
            "Done. You will get less \\(name).", "Undo", "Could not change that.",
            "What helped: \\(names)", "What held it back: \\(names)", "This week", "Let Taizo help the engine",
            "Taizo can name your taste islands, suggest artists you may not know once a week, and add genres to songs that no source knows, a batch at a time. It sends genre names, artist names and song titles to the cloud assistant, never play counts or dates, and it counts against your monthly allowance. Off unless you turn it on.",
            "Started a station from \\(name).",
            "I could not find \\(name) in your library, your genres or your playlists, so I did not start a station.",
        ] {
            #expect(all.contains(text), "missing: \(text)")
        }
        for literal in all {
            let lower = literal.lowercased()
            #expect(!lower.contains("learn"), "says learn: \(literal)")
            for word in forbidden { #expect(!lower.contains(word), "says \(word): \(literal)") }
        }
    }

    /// Endless Listening, milestone E1: the words are Android's `strings_endless.xml`; the introduction's copy is exact; nothing says "learn",
    /// a word the app never says, or the name of another service's feature.
    @Test func theWordsOfEndlessListeningAreAndroidsAndNameNothingElse() throws {
        let strings = try String(contentsOf: appRoot.appendingPathComponent("Features/Brain/EndlessStrings.swift"), encoding: .utf8)
        let all = literals(strings)
        for text in [
            "Endless Listening", "Play a few songs first. Endless Listening starts from what you play.",
            "Starts from \\(names) and keeps going.", "Starts from what you play and keeps going.", "Keeps going",
            "More about Endless Listening", "How it works", "Keeps going from what you play, until you stop it", "Ask the host",
            "Something new", "Back to familiar", "Why this song", "More upbeat", "Slower", "Surprise me",
            "Okay. The next songs lean towards new music, until this station ends.", "Okay. Back to your usual mix of new and familiar.",
            "Okay. One song that leans new is next.", "Okay. \\(count) songs that lean new are next.",
            "Okay. One livelier song is next.", "Okay. \\(count) livelier songs are next.",
            "Okay. One slower song is next.", "Okay. \\(count) slower songs are next.", "Endless Listening is already playing.",
            "Music that keeps going.", "Endless Listening starts from what you play and keeps adding more until you stop it.",
            "A host, if you want one.", "Short notes between songs say why something is here. Ask for something new, or why a song was picked.",
            "You decide.", "Choose how much is new, skip anything, and turn the notes off any time.",
            "Start listening", "Not now", "Host notes", "Replay the introduction",
            // Milestone E2: the spoken host (Android `strings_endless.xml`, word for word).
            "Host notes, spoken notes and how it works", "Spoken host notes",
            "The host says a note out loud now and then, with the music turned down. Uses the voice on this phone.",
            "Test the voice", "Hear how the host sounds", "Starting the voice", "This is how the host sounds.",
            "This phone has no English voice that works without the internet.", "The host is talking right now.",
            "Not during a call.", "The voice did not start. Try again.", "Host voice log",
            "The last 20 notes: said or skipped, and why", "Nothing yet.", "Close",
        ] {
            #expect(all.contains(text), "missing: \(text)")
        }
        var sources = [("EndlessStrings.swift", strings)]
        for name in ["Features/Brain/EndlessIntroView.swift", "Features/Brain/EndlessHostViews.swift",
                     "Features/Settings/Categories/EndlessSettingsSection.swift", "Services/Brain/HostVoiceController.swift",
                     "Playback/HostSpeaker.swift", "Playback/HostDuck.swift"] {
            sources.append((name, try String(contentsOf: appRoot.appendingPathComponent(name), encoding: .utf8)))
        }
        for (name, text) in sources {
            for literal in literals(text) {
                let lower = literal.lowercased()
                #expect(!lower.contains("learn"), "\(name) says learn: \(literal)")
                #expect(!lower.contains("spotify dj") && !lower.contains("apple"), "\(name) names another feature: \(literal)")
                for word in forbidden { #expect(!lower.contains(word), "\(name) says \(word): \(literal)") }
            }
        }
    }

    @Test func theScanReadsLiteralsAndSkipsComments() {
        let found = literals("let a = \"One \\(x) two\" // \"not this\"\n/* \"nor this\" */ let b = \"Three\"")
        #expect(found == ["One \\(x) two", "Three"])
    }
}
