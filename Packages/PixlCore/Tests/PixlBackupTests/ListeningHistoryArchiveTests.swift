import Foundation
import PixlLibrary
import PixlModel
import Testing
@testable import PixlBackup

/// Listening history › Import from a file: the ZIP Spotify / Google Takeout sends, or a JSON file taken out of it.
@Suite("Listening history archive")
struct ListeningHistoryArchiveTests {
    static let extended = #"[{"ts":"2024-03-01T12:00:00Z","ms_played":215000,"master_metadata_track_name":"Blinding Lights","master_metadata_album_artist_name":"The Weeknd","spotify_track_uri":"spotify:track:0VjIjW4GlUZAMYd2vXMi3b","reason_end":"trackdone"}]"#
    static let video = #"[{"ts":"2024-03-01T12:00:00Z","ms_played":1000,"master_metadata_track_name":"A video"}]"#
    static let takeout = #"[{"header":"YouTube Music","title":"Watched Get Lucky","titleUrl":"https://music.youtube.com/watch?v=5NV6Rdv1a3I","subtitles":[{"name":"Daft Punk - Topic"}],"time":"2024-04-10T20:15:30Z"}]"#

    @Test func aSpotifyZipReadsOnlyTheAudioHistory() throws {
        var zip = ZipWriter()
        zip.addStored(name: "Spotify Extended Streaming History/", data: [])
        zip.addStored(name: "Spotify Extended Streaming History/Streaming_History_Audio_2024.json", data: Array(Self.extended.utf8))
        zip.addStored(name: "Spotify Extended Streaming History/Streaming_History_Video_2024.json", data: Array(Self.video.utf8))
        zip.addStored(name: "Spotify Extended Streaming History/ReadMeFirst_ExtendedStreamingHistory.pdf", data: [1, 2, 3])
        var fractions: [Double] = []
        let result = try ListeningHistoryArchive.read(fileName: "my_spotify_data.zip", bytes: zip.finish()) { fractions.append($0) }
        #expect(result.filesRead == 1 && result.kinds == [.spotifyExtended])
        #expect(result.plays.map(\.title) == ["Blinding Lights"])
        #expect(result.plays[0].source == .spotifyExport)
        #expect(fractions.last == 1)
    }

    @Test func aTakeoutZipAndLooseFiles() throws {
        var zip = ZipWriter()
        zip.addStored(name: "Takeout/YouTube and YouTube Music/history/watch-history.json", data: Array(Self.takeout.utf8))
        zip.addStored(name: "Takeout/YouTube and YouTube Music/history/search-history.json", data: Array("[]".utf8))
        let result = try ListeningHistoryArchive.read(fileName: "takeout-2024.zip", bytes: zip.finish())
        #expect(result.kinds == [.takeoutWatchHistory] && result.plays.first?.videoId == "5NV6Rdv1a3I")

        let loose = try ListeningHistoryArchive.read(fileName: "Streaming_History_Audio_2024.json", bytes: Array(Self.extended.utf8))
        #expect(loose.plays.count == 1)
        // A JSON file with an unhelpful name is recognised by its content.
        let renamed = try ListeningHistoryArchive.read(fileName: "history.json", bytes: Array(Self.takeout.utf8))
        #expect(renamed.kinds == [.takeoutWatchHistory])
    }

    @Test func htmlTakeoutAndOtherFilesAreExplained() throws {
        var zip = ZipWriter()
        zip.addStored(name: "Takeout/YouTube and YouTube Music/history/watch-history.html", data: Array("<html></html>".utf8))
        let html = try ListeningHistoryArchive.read(fileName: "takeout.zip", bytes: zip.finish())
        #expect(html.foundHTMLHistory && html.plays.isEmpty)
        #expect(throws: ListeningHistoryArchive.Failure.notHistory) {
            try ListeningHistoryArchive.read(fileName: "photo.json", bytes: Array(#"{"a":1}"#.utf8))
        }
        #expect(throws: ListeningHistoryArchive.Failure.self) {
            try ListeningHistoryArchive.read(fileName: "broken.zip", bytes: [0x50, 0x4B, 0x03, 0x04, 0, 0])
        }
    }
}
