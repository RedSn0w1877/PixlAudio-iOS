import Foundation
import Testing
@testable import PixlLibrary

/// Song Tap's words (the Android `strings_songtap.xml`, on iOS `SongTapStrings.swift` and the screens beside it): none may
/// use a word the app never says, and none may say "Apple". The app's sources are read as text: nothing under `App/`
/// compiles on this machine.
@Suite("Song Tap copy")
struct SongTapCopyTests {
    private let forbidden = ["lossless", "hi-res", "hires", "dolby", "atmos", "360 reality", "claude", "anthropic",
                             "binilyrics", "enhanced", "learn"]

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
        var files: [URL] = []
        for folder in ["Features/SongTap", "Services/SongTap"] {
            let dir = appRoot.appendingPathComponent(folder, isDirectory: true)
            files += try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
                .map { dir.appendingPathComponent($0) }
        }
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func noSongTapStringUsesAWordTheAppNeverSays() throws {
        let files = try sources()
        #expect(files.count >= 6, "expected Song Tap's files under \(appRoot.path), found \(files.count)")
        var count = 0
        for file in files {
            for literal in literals(file.text) {
                count += 1
                let lower = literal.lowercased()
                for word in forbidden {
                    #expect(!lower.contains(word), "\(file.name) says \"\(word)\": \(literal)")
                }
                #expect(!literal.contains("Apple"), "\(file.name) says Apple: \(literal)")
            }
        }
        #expect(count > 40, "only \(count) literals were read")
    }

    @Test func theStringsFileHoldsTheSentencesOfAndroid() throws {
        let strings = try String(contentsOf: appRoot.appendingPathComponent("Features/SongTap/SongTapStrings.swift"), encoding: .utf8)
        for sentence in ["Share songs with a phone nearby", "Allow Song Tap", "Added to your library", "Already in your library",
                         "Couldn't find this one here", "Add to your library?", "That isn't a PixlAudio song code."] {
            #expect(strings.contains(sentence), "\(sentence)")
        }
    }
}
