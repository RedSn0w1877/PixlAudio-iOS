import Foundation
import Testing
@testable import PixlTags

@Suite("Metadata mapping and editing")
struct MetadataEditorTests {
    // MARK: AudioMetadataReader mapping

    @Test func fieldMappingFollowsAudioMetadataReader() {
        let map: TagProperties = [
            "TITLE": ["  "], "ARTIST": ["Artist"], "ALBUM ARTIST": ["Fallback AA"], "BAND": ["Band"],
            "ALBUM": ["Album"], "GENRE": ["Pop"], "TCOM": ["Composer via TCOM"], "UNSYNCEDLYRICS": ["words"],
            "TRACK": ["07/10"], "DISCNUMBER": ["2/3"], "DATE": ["2019-05-01"],
            "REPLAYGAIN_TRACK_GAIN": ["junk"], "REPLAYGAIN_TRACK_GAIN_DB": ["-3,5 dB"], "R128_ALBUM_GAIN": ["-512"],
        ]
        let m = AudioMetadataMapper.metadata(properties: map, pictures: [])
        #expect(m.title == nil)  // blank
        #expect(m.artist == "Artist")
        #expect(m.albumArtist == "Fallback AA")
        #expect(m.album == "Album")
        #expect(m.genre == "Pop")
        #expect(m.composer == "Composer via TCOM")
        #expect(m.lyrics == "words")
        #expect(m.trackNumber == 7)
        #expect(m.discNumber == 2)
        #expect(m.year == 2019)
        #expect(m.replayGainTrackGainDb == -3.5)    // an unparsable first key falls through to the next
        #expect(m.replayGainAlbumGainDb == -512)    // R128 is read as dB, like Android
        #expect(m.artwork == nil)
        let year = AudioMetadataMapper.metadata(properties: ["DATE": ["abcd"], "YEAR": ["1984"], "TRACKNUMBER": ["x/1"]], pictures: [])
        #expect(year.year == 1984)
        #expect(year.trackNumber == nil)
        #expect(AudioMetadataMapper.metadata(properties: ["ALBUMARTIST": ["AA"], "BAND": ["B"]], pictures: []).albumArtist == "AA")
        #expect(AudioMetadataMapper.metadata(properties: ["BAND": ["B"]], pictures: []).albumArtist == "B")
    }

    @Test func artworkUsesOnlyTheFirstValidPicture() {
        let png = TagPicture(data: Data(B.png), mimeType: "")
        let m = AudioMetadataMapper.metadata(properties: [:], pictures: [png])
        #expect(m.artwork == TagArtwork(bytes: Data(B.png), mimeType: "image/png"))  // blank MIME → sniffed
        let invalidFirst = AudioMetadataMapper.metadata(properties: [:], pictures: [TagPicture(data: Data([1, 2, 3, 4]), mimeType: "image/png"), png])
        #expect(invalidFirst.artwork == nil)
        #expect(AudioMetadataMapper.metadata(properties: [:], pictures: [png], readArtwork: false).artwork == nil)
        let webp = Data(B.latin1("RIFF") + [0, 0, 0, 0] + B.latin1("WEBPVP8 "))
        #expect(ImageSniffing.isLikelyDecodableImage(webp))
        #expect(ImageSniffing.guessContentType(webp) == "audio/x-wav")  // Java's guess, as Android would report it
        #expect(!ImageSniffing.isLikelyDecodableImage(Data([0xFF, 0xD8])))
        #expect(ImageSniffing.imageExtension(forMimeType: "IMAGE/JPG") == "jpg")
        #expect(ImageSniffing.imageExtension(forMimeType: nil) == nil)
    }

    // MARK: ReplayGain

    @Test func replayGainReading() {
        #expect(ReplayGainTags.values(from: [:]) == nil)
        #expect(ReplayGainTags.values(from: ["REPLAYGAIN_ALBUM_GAIN": ["-8.20 dB"]]) == ReplayGainValues(albumGainDb: -8.2))
        // ReplayGainManager: the first present key decides even when it does not parse (no comma support either).
        #expect(ReplayGainTags.extractGainValue(["REPLAYGAIN_TRACK_GAIN": ["-6,5 dB"], "R128_TRACK_GAIN": ["1"]],
                                                keys: ReplayGainTags.trackGainKeys) == nil)
        #expect(ReplayGainTags.extractReplayGainDb(["REPLAYGAIN_TRACK_GAIN": ["-6,5 dB"]], keys: ReplayGainTags.trackGainKeys) == -6.5)
        #expect(ReplayGainTags.volumeMultiplier(ReplayGainValues(trackGainDb: -6.0206)) < 0.5001)
        #expect(ReplayGainTags.volumeMultiplier(ReplayGainValues(trackGainDb: 20)) == 2)
        #expect(ReplayGainTags.volumeMultiplier(ReplayGainValues(trackGainDb: 0, albumGainDb: -20), useAlbumGain: true) == Float(Foundation.pow(10.0, -1.0)))
    }

    @Test func kotlinNumberFormatting() {
        #expect(KotlinText.formatFixed2(-6.54) == "-6.54")
        #expect(KotlinText.formatFixed2(0.125) == "0.13")
        #expect(KotlinText.formatFixed2(-0.0) == "-0.00")
        #expect(KotlinText.formatFixed2(9.995) == "9.99")
        #expect(KotlinText.formatFixed2(99.995) == "100.00")
        #expect(KotlinText.formatFixed2(1e-30) == "0.00")
        #expect(KotlinText.formatFixed2(123456789) == "123456792.00")
        #expect(KotlinText.formatFixed(0.5, precision: 0) == "1")
        #expect(KotlinText.removingTrailingDbUnit("1 d B ") == "1")
        #expect(KotlinText.removingTrailingDbUnit("dB 1") == "dB 1")
        #expect(KotlinText.removingDb("-1dBdb") == "-1")
    }

    // MARK: SongMetadataEditor

    static func mp3(lyrics: String? = "old lyrics") -> Data {
        var frames = B.frame24("TIT2", B.text(0, B.latin1("Indian Summr")))
            + B.frame24("TPE1", B.text(0, B.latin1("Blood Cultures")))
            + B.frame24("TPE2", B.text(0, B.latin1("Old AA")))
            + B.frame24("TCOM", B.text(0, B.latin1("Old composer")))
            + B.frame24("TPOS", B.text(0, B.latin1("1/2")))
            + B.frame24("TXXX", B.text(0, B.latin1("REPLAYGAIN_ALBUM_GAIN") + [0] + B.latin1("-9.00 dB")))
            + B.frame24("APIC", B.apicBody(mime: "image/png", type: 3, description: [], data: B.png))
        if let lyrics { frames += B.frame24("USLT", [0] + B.latin1("eng") + [0] + B.latin1(lyrics)) }
        return Data(B.id3(4, frames + [UInt8](repeating: 0, count: 512)) + B.mp3Frames(2))
    }

    static func edit(lyrics: String?, albumArtist: String? = "", composer: String? = "", disc: Int? = nil,
                     rgTrack: String? = nil, rgAlbum: String? = nil, cover: CoverArtUpdate? = nil) -> MetadataEdit {
        MetadataEdit(title: "Indian Summer", artist: "Blood Cultures", album: "Happy Birthday", albumArtist: albumArtist,
                     composer: composer, genre: "  Indie  ", lyrics: lyrics, trackNumber: 1, discNumber: disc,
                     replayGainTrackGainDb: rgTrack, replayGainAlbumGainDb: rgAlbum, coverArt: cover)
    }

    static func apply(_ edit: MetadataEdit, _ data: Data = mp3(), ext: String = "mp3") throws -> AudioTags {
        let result = SongMetadataEditor.edit(edit, fileData: data, fileExtension: ext)
        guard case .success(let written) = result else { throw TagError.invalid("\(result)") }
        return try AudioTagReader.read(written.data)
    }

    /// `MetadataEditLyricsPreservationTest.titleOnlySave_leavesStoredLyricsAndTapSyncAlone` (file half): nil lyrics
    /// keep the file's lyrics tag.
    @Test func titleOnlySaveLeavesTheLyricsTagAlone() throws {
        let tags = try Self.apply(Self.edit(lyrics: nil))
        let p = tags.properties
        #expect(p["TITLE"] == ["Indian Summer"])
        #expect(p["LYRICS"] == ["old lyrics"])
        // The untouched USLT frame is the original one (language kept).
        #expect(tags.id3v2?.unsyncedLyrics.first?.language == "eng")
    }

    /// `clearingTheLyricsField_stillResetsLyrics` (file half): blank lyrics remove the tag.
    @Test func clearingTheLyricsFieldRemovesTheTag() throws {
        let tags = try Self.apply(Self.edit(lyrics: "  "))
        #expect(tags.properties["LYRICS"] == nil)
        #expect(tags.id3v2?.unsyncedLyrics.isEmpty == true)
    }

    /// `editedLyrics_areWritten` (file half): edited lyrics are trimmed and written.
    @Test func editedLyricsAreWrittenTrimmed() throws {
        let tags = try Self.apply(Self.edit(lyrics: "new words\n"))
        #expect(tags.properties["LYRICS"] == ["new words"])
        #expect(tags.id3v2?.unsyncedLyrics.first?.description == "LYRICS")
    }

    @Test func propertyUpdatesFollowTheTagLibPath() throws {
        let tags = try Self.apply(Self.edit(lyrics: nil, albumArtist: "  ", composer: " ", disc: 0, rgTrack: "-6,5 dB", rgAlbum: ""))
        let p = tags.properties
        #expect(p["ARTIST"] == ["Blood Cultures"])
        #expect(p["ALBUM"] == ["Happy Birthday"])
        #expect(p["ALBUMARTIST"] == ["Old AA"])     // blank album artist: keep the existing one
        #expect(p["COMPOSER"] == nil)               // blank composer: removed
        #expect(p["GENRE"] == ["Indie"])            // trimmed
        #expect(p["TRACKNUMBER"] == ["1"])
        #expect(p["DISCNUMBER"] == nil)             // 0 removes the disc number
        #expect(p["REPLAYGAIN_TRACK_GAIN"] == ["-6.50 dB"])
        #expect(p["REPLAYGAIN_ALBUM_GAIN"] == nil)  // cleared
        #expect(tags.pictures.count == 1)           // no cover update: pictures untouched
        #expect(tags.id3v2?.version == 4)

        let more = try Self.apply(Self.edit(lyrics: nil, albumArtist: "New AA", composer: "C", disc: 2))
        #expect(more.properties["ALBUMARTIST"] == ["New AA"])
        #expect(more.properties["COMPOSER"] == ["C"])
        #expect(more.properties["DISCNUMBER"] == ["2"])
        #expect(more.properties["REPLAYGAIN_ALBUM_GAIN"] == ["-9.00 dB"])  // nil: keep
    }

    @Test func coverArtUpdates() throws {
        let replaced = try Self.apply(Self.edit(lyrics: nil, cover: CoverArtUpdate(bytes: Data(B.jpeg))))
        #expect(replaced.pictures == [TagPicture(data: Data(B.jpeg), mimeType: "image/jpeg", description: "Front Cover", pictureType: 3)])
        let removed = try Self.apply(Self.edit(lyrics: nil, cover: CoverArtUpdate(isDeletion: true)))
        #expect(removed.pictures.isEmpty)
        let ignored = try Self.apply(Self.edit(lyrics: nil, cover: CoverArtUpdate()))
        #expect(ignored.pictures.count == 1)
        #expect(SongMetadataEditor.pictures(for: nil) == nil)
    }

    @Test func editFailures() {
        func failure(_ r: Result<TagWriteResult, MetadataEditFailure>) -> MetadataEditFailure? {
            if case .failure(let f) = r { return f }
            return nil
        }
        var blank = Self.edit(lyrics: nil)
        blank.title = " "
        #expect(failure(SongMetadataEditor.edit(blank, fileData: Self.mp3(), fileExtension: "mp3"))
                == MetadataEditFailure(.invalidInput, "Title cannot be empty"))
        #expect(failure(SongMetadataEditor.edit(Self.edit(lyrics: nil, rgTrack: "loud"), fileData: Self.mp3(), fileExtension: "mp3"))
                == MetadataEditFailure(.invalidInput, "Track ReplayGain must be a valid dB value"))
        #expect(failure(SongMetadataEditor.edit(Self.edit(lyrics: nil, rgTrack: "1", rgAlbum: "x"), fileData: Self.mp3(), fileExtension: "mp3"))
                == MetadataEditFailure(.invalidInput, "Album ReplayGain must be a valid dB value"))
        // MP4 content is never written here, whatever the extension says.
        let m4a = Data(B.m4a(B.textItem("\u{A9}nam", "x")))
        #expect(failure(SongMetadataEditor.edit(Self.edit(lyrics: nil), fileData: m4a, fileExtension: "mp3"))?.error == .unsupportedFormat)
        #expect(failure(SongMetadataEditor.edit(Self.edit(lyrics: nil), fileData: m4a, fileExtension: "m4a"))?.error == .unsupportedFormat)
        let opus = Data(B.latin1("OggS") + [UInt8](repeating: 0, count: 22) + [1, 19] + B.latin1("OpusHead") + [UInt8](repeating: 0, count: 11))
        #expect(failure(SongMetadataEditor.edit(Self.edit(lyrics: nil), fileData: opus, fileExtension: "ogg"))
                == MetadataEditFailure(.unsupportedFormat, "Unsupported format: .opus"))
        let brokenFlac = Data(B.latin1("fLaC") + [0x84, 0, 0, 4] + [0, 0, 0, 0])
        #expect(failure(SongMetadataEditor.edit(Self.edit(lyrics: nil), fileData: brokenFlac, fileExtension: "flac"))
                == MetadataEditFailure(.taglibError, "Failed to write metadata to file"))
        #expect(MetadataEditError.allCases.map(\.rawValue) == ["FILE_NOT_FOUND", "NO_WRITE_PERMISSION", "INVALID_INPUT",
                                                               "UNSUPPORTED_FORMAT", "TAGLIB_ERROR", "TIMEOUT",
                                                               "FILE_CORRUPTED", "IO_ERROR", "UNKNOWN"])
    }

    @Test func flacEditsAndRouting() throws {
        let flac = Data(FLACTests.sample())
        let tags = try Self.apply(Self.edit(lyrics: "", rgTrack: "+1 dB"), flac, ext: "mp3")  // magic bytes win
        #expect(tags.container == .flac)
        let p = tags.properties
        #expect(p["TITLE"] == ["Indian Summer"])
        #expect(p["LYRICS"] == nil)
        #expect(p["REPLAYGAIN_TRACK_GAIN"] == ["1.00 dB"])
        #expect(p["ARTIST"] == ["Blood Cultures"])
        // FLAC behind an ID3v2 tag is written as FLAC (Android's check would call it MP3).
        let prefixed = Data(B.id3(3, B.frame23("TIT2", B.text(0, B.latin1("x")))) + FLACTests.sample())
        let fromPrefixed = try Self.apply(Self.edit(lyrics: nil), prefixed, ext: "flac")
        #expect(fromPrefixed.container == .flac)
        #expect(fromPrefixed.flac?.vorbisComment?.fields["TITLE"] == ["Indian Summer"])
        #expect(fromPrefixed.id3v2?.properties["TITLE"] == ["x"])
        #expect(AudioContainer.effectiveExtension(fileExtension: "MP3", detected: .flac) == "flac")
        #expect(AudioContainer.effectiveExtension(fileExtension: "ogg", detected: .oggOpus) == "opus")
        #expect(AudioContainer.effectiveExtension(fileExtension: "Opus", detected: .unknown) == "opus")
        #expect(AudioContainer.effectiveExtension(fileExtension: "mp3", detected: .mp3) == "mp3")
    }

    @Test func mp3WithOnlyID3v1() throws {
        let v1 = ID3v1Tag(title: "V1 title", artist: "V1 artist", album: "A", year: "2001", comment: "c", track: 4, genre: 17)
        let file = Data(B.mp3Frames(1)) + v1.render()
        let before = try AudioTagReader.read(file)
        #expect(before.properties.dictionary == ["TITLE": ["V1 title"], "ARTIST": ["V1 artist"], "ALBUM": ["A"],
                                                 "COMMENT": ["c"], "GENRE": ["Rock"], "DATE": ["2001"], "TRACKNUMBER": ["4"]])
        let after = try Self.apply(Self.edit(lyrics: nil), file)
        #expect(after.id3v2?.properties["COMMENT"] == ["c"])  // the ID3v1 properties seed the new ID3v2 tag
        #expect(after.id3v1?.title == "Indian Summer")
        #expect(after.id3v1?.genre == UInt8(ID3v1Genres.index(of: "Indie")))
        #expect(after.id3v1?.track == 1)
        #expect(ID3v1Tag.parse(v1.render().byteArray) == v1)
    }
}
