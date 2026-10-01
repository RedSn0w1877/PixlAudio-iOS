import Foundation
import PixlFoundation
import Testing
@testable import PixlTags

/// Vectors produced by the Android app's compiled classes on the JVM (`tools/android-reference/TagsGen.java`).
@Suite("Android golden vectors")
struct AndroidGoldenTests {
    struct Line {
        let fn: String
        let input: JSONValue
        let output: JSONValue
    }

    static func lines() throws -> [Line] {
        let text = String(decoding: try Fixture.data("tags-android-golden.jsonl"), as: UTF8.self)
        return try text.split(separator: "\n").map { raw in
            let v = try JSONParser().parse(String(raw))
            return Line(fn: v["fn"]!.stringValue!, input: v["in"]!, output: v["out"]!)
        }
    }

    static func float(_ v: JSONValue) -> Float? {
        guard let s = v.stringValue else { return nil }
        return Float(bitPattern: UInt32(s.dropFirst(2), radix: 16)!)
    }

    static func same(_ a: Float?, _ b: Float?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return x.bitPattern == y.bitPattern || (x.isNaN && y.isNaN)
        default: return false
        }
    }

    static func string(_ v: JSONValue) -> String? {
        if let s = v.stringValue { return s }
        if let o = v.objectValue, let unit = o["repeat"]?.stringValue, let n = o["count"]?.int64Value {
            return String(repeating: unit, count: Int(n))
        }
        return nil
    }

    @Test func everyVectorMatches() throws {
        let all = try Self.lines()
        #expect(all.count > 1000)
        var failures: [String] = []
        var counts: [String: Int] = [:]
        for line in all {
            counts[line.fn, default: 0] += 1
            switch line.fn {
            case "parseGainString":
                let got = ReplayGainTags.parseGainString(line.input.stringValue!)
                if !Self.same(got, Self.float(line.output)) { failures.append("\(line.fn) \(line.input) → \(String(describing: got))") }
            case "parseReplayGainDb":
                let got = ReplayGainTags.parseReplayGainDb(line.input.stringValue)
                if !Self.same(got, Self.float(line.output)) { failures.append("\(line.fn) \(line.input) → \(String(describing: got))") }
            case "toFloatOrNull":
                let got = KotlinText.toFloatOrNull(line.input.stringValue!)
                if !Self.same(got, Self.float(line.output)) { failures.append("\(line.fn) \(line.input) → \(String(describing: got))") }
            case "parseReplayGainUpdate", "parseReplayGainUpdateAlbum":
                let field = line.fn == "parseReplayGainUpdate" && !line.input.isNull ? "Track ReplayGain" : "Album ReplayGain"
                let got = ReplayGainTags.parseUpdate(line.input.stringValue, fieldName: field)
                let want: Result<ReplayGainUpdate, MetadataEditFailure>
                if let s = line.output["set"]?.stringValue { want = .success(.set(s)) }
                else if line.output["keep"] != nil { want = .success(.keep) }
                else if line.output["clear"] != nil { want = .success(.clear) }
                else { want = .failure(MetadataEditFailure(.invalidInput, line.output["error"]!.stringValue!)) }
                if got != want { failures.append("\(line.fn) \(line.input) → \(got) want \(want)") }
            case "gainDbToVolume":
                let a = line.input.arrayValue!
                let got = ReplayGainTags.gainDbToVolume(Self.float(a[0])!, preAmpDb: Self.float(a[1])!)
                if !Self.same(got, Self.float(line.output)) { failures.append("\(line.fn) \(line.input) → \(got)") }
            case "getVolumeMultiplier":
                let got: Float
                if line.input.isNull {
                    got = ReplayGainTags.volumeMultiplier(nil)
                } else {
                    let a = line.input.arrayValue!
                    got = ReplayGainTags.volumeMultiplier(ReplayGainValues(trackGainDb: Self.float(a[0]), albumGainDb: Self.float(a[1])),
                                                          useAlbumGain: a[2].boolValue!, preAmpDb: Self.float(a[3])!)
                }
                if !Self.same(got, Self.float(line.output)) { failures.append("\(line.fn) \(line.input) → \(got)") }
            case "toIntOrNull":
                let got = KotlinText.toIntOrNull(line.input.stringValue!)
                let want = line.output.int64Value.map { Int($0) }
                if got != want { failures.append("\(line.fn) \(line.input) → \(String(describing: got))") }
            case "validateMetadataInput":
                let a = line.input.arrayValue!.map(Self.string)
                let got = SongMetadataEditor.validate(title: a[0]!, artist: a[1]!, album: a[2]!, albumArtist: a[3],
                                                      composer: a[4], genre: a[5]!, lyrics: a[6])
                if got != line.output.stringValue { failures.append("\(line.fn) #\(counts[line.fn]!) → \(String(describing: got))") }
            case "detectContainerFormat":
                let got = AudioContainer.detect(Data(Fixture.hex(line.input.stringValue!)))
                let names: [AudioContainer: String] = [.mp3: "MP3", .mp4: "MP4", .flac: "FLAC", .oggOpus: "OGG_OPUS",
                                                       .oggVorbis: "OGG_VORBIS", .ogg: "OGG", .wav: "WAV", .unknown: "UNKNOWN"]
                if names[got] != line.output.stringValue { failures.append("\(line.fn) \(line.input) → \(got)") }
            case "isProblematicFlacFile":
                let a = line.input.arrayValue!
                let got = FLACStreamInfo.analyze(fileHeader: Data(Fixture.hex(a[1].stringValue!)), fileExtension: a[0].stringValue!)
                let text: String
                switch got {
                case .notFlac: text = "NotFlac"
                case .safe(let r, let b): text = "Safe(sampleRate=\(r), bitsPerSample=\(b))"
                case .problematic(let r, let b): text = "Problematic(sampleRate=\(r), bitsPerSample=\(b))"
                }
                if text != line.output.stringValue { failures.append("\(line.fn) \(line.input) → \(text)") }
            case "guessContentTypeFromStream":
                let got = ImageSniffing.guessContentType(Data(Fixture.hex(line.input.stringValue!)))
                if got != line.output.stringValue { failures.append("\(line.fn) \(line.input) → \(String(describing: got))") }
            default:
                failures.append("unknown fn \(line.fn)")
            }
        }
        let report = "\(failures.count) mismatches:\n" + failures.prefix(40).joined(separator: "\n")
        #expect(failures.isEmpty, "\(report)")
        for fn in ["parseGainString", "parseReplayGainDb", "toFloatOrNull", "parseReplayGainUpdate", "gainDbToVolume",
                   "getVolumeMultiplier", "toIntOrNull", "validateMetadataInput", "detectContainerFormat",
                   "isProblematicFlacFile", "guessContentTypeFromStream"] {
            #expect((counts[fn] ?? 0) > 0, "no vectors for \(fn)" as Comment)
        }
    }
}
