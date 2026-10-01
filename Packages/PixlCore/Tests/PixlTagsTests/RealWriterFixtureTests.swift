import Foundation
import Testing
@testable import PixlTags

/// Files written by a real third-party tagger (FFmpeg 8 / Lavf 62: ID3v2.4, ID3v2.3 + ID3v1, FLAC with a PICTURE
/// block, M4A with `ilst` + `covr`), generated once with the commands in `docs/test-parity/s03d-tags.md`.
@Suite("Real-writer fixtures")
struct RealWriterFixtureTests {
    static let title = "Ünïcode Title 日本"

    func checkCommon(_ p: TagProperties) {
        #expect(p["TITLE"] == [Self.title])
        #expect(p["ARTIST"] == ["Artist A"])
        #expect(p["ALBUMARTIST"] == ["Album Artist"])
        #expect(p["ALBUM"] == ["The Album"])
        #expect(p["TRACKNUMBER"] == ["3/12"])
        #expect(p["DATE"] == ["2021"])
        #expect(p["GENRE"] == ["Rock"])
        #expect(p["COMPOSER"] == ["Composer C"])
    }

    @Test(arguments: ["ffmpeg-id3v24.mp3", "ffmpeg-id3v23.mp3"])
    func ffmpegMP3(_ name: String) throws {
        let data = try Fixture.data(name)
        let tags = try AudioTagReader.read(data)
        #expect(tags.container == .mpeg)
        checkCommon(tags.properties)
        #expect(tags.properties["DISCNUMBER"] == ["1/2"])
        #expect(tags.properties["REPLAYGAIN_TRACK_GAIN"] == ["-6.54 dB"])
        #expect(tags.properties["USLT"] == ["line one"])  // FFmpeg stores "lyrics" as TXXX:USLT
        #expect(tags.pictures.count == 1)
        #expect(tags.pictures.first?.mimeType == "image/png")
        #expect(tags.pictures.first?.pictureType == 3)
        let m = AudioMetadataMapper.metadata(properties: tags.properties, pictures: tags.pictures)
        #expect(m.trackNumber == 3)
        #expect(m.discNumber == 1)
        #expect(m.year == 2021)
        #expect(m.replayGainTrackGainDb == -6.54)
        #expect(m.replayGainAlbumGainDb == -8.2)   // "-8,20 dB": decimal comma accepted by AudioMetadataReader
        #expect(ReplayGainTags.values(from: tags.properties) == ReplayGainValues(trackGainDb: -6.54, albumGainDb: nil))
        #expect(m.artwork?.mimeType == "image/png")
        if name.contains("23") {
            #expect(tags.id3v2?.version == 3)
            #expect(tags.id3v1?.artist == "Artist A")
            #expect(tags.id3v1?.album == "The Album")
        } else {
            #expect(tags.id3v2?.version == 4)
            #expect(tags.id3v1 == nil)
        }

        // Rewrite through the editor and read back.
        let edit = MetadataEdit(title: "Edited", artist: "Artist A", album: "The Album", genre: "Rock",
                                lyrics: "new lyrics", trackNumber: 4, discNumber: nil, replayGainTrackGainDb: "-1")
        guard case .success(let written) = SongMetadataEditor.edit(edit, fileData: data, fileExtension: "mp3") else {
            Issue.record("edit failed"); return
        }
        let back = try AudioTagReader.read(written.data)
        #expect(back.properties["TITLE"] == ["Edited"])
        #expect(back.properties["TRACKNUMBER"] == ["4"])
        #expect(back.properties["LYRICS"] == ["new lyrics"])
        #expect(back.properties["REPLAYGAIN_TRACK_GAIN"] == ["-1.00 dB"])
        #expect(back.properties["ALBUMARTIST"] == ["Album Artist"])
        #expect(back.pictures == tags.pictures)
        let audioStart = try #require(ID3v2Tag.totalSize(in: data))
        let newStart = try #require(ID3v2Tag.totalSize(in: written.data))
        let audioEnd = data.count - (tags.id3v1 == nil ? 0 : 128)
        #expect(written.data.subdata(offsets: newStart..<(newStart + audioEnd - audioStart)) == data.subdata(offsets: audioStart..<audioEnd))
    }

    @Test func ffmpegFLAC() throws {
        let data = try Fixture.data("ffmpeg.flac")
        let tags = try AudioTagReader.read(data)
        #expect(tags.container == .flac)
        checkCommon(tags.properties)
        #expect(tags.properties["DISCNUMBER"] == ["1/2"])
        #expect(tags.properties["REPLAYGAIN_ALBUM_GAIN"] == ["-8,20 dB"])
        #expect(tags.flac?.vorbisComment?.vendor == "Lavf62.12.102")
        #expect(tags.flac?.streamInfo?.sampleRate == 22_050)
        #expect(tags.pictures.first?.mimeType == "image/png")
        // FFmpeg leaves 8 KiB of padding, more than TagLib keeps for a file this small (max(1 %, 4 KiB)), so the
        // rewrite shrinks it to 4 KiB.
        var flac = try #require(tags.flac)
        var p = flac.properties
        p["TITLE"] = ["Short"]
        flac.setProperties(p)
        let result = flac.render(into: data)
        #expect(!result.fitsInPlace)
        #expect(result.data.count < data.count - 4000)
        #expect(try FLACFile.parse(result.data).properties == p)
    }

    @Test func ffmpegM4A() throws {
        let data = try Fixture.data("ffmpeg.m4a")
        let tags = try AudioTagReader.read(data)
        #expect(tags.container == .mp4)
        checkCommon(tags.properties)
        #expect(tags.properties["DISCNUMBER"] == ["1/2"])
        #expect(tags.properties["LYRICS"] == ["line one"])
        #expect(tags.properties["ENCODEDBY"] == ["Lavf62.12.102"])
        #expect(tags.pictures.count == 1)
        #expect(tags.pictures.first?.mimeType == "image/png")
        let m = try AudioMetadataMapper.read(data)
        #expect(m.lyrics == "line one")
        #expect(m.albumArtist == "Album Artist")
    }
}
