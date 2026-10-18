import Foundation
import Testing
import PixlModel
@testable import PixlLibrary

@Suite struct SongFilterIndexTests {
    private static func song(_ id: String, _ title: String, _ artist: String, _ album: String) -> Song {
        Song(id: id, title: title, artist: artist, artistId: 1,
             artists: [ArtistRef(id: 1, name: artist, isPrimary: true)], album: album, albumId: 1, path: "",
             contentUriString: "", albumArtUriString: nil, duration: 1000, mimeType: nil, bitrate: nil, sampleRate: nil)
    }

    private let songs: [Song] = [
        Self.song("1", "D\u{E9}j\u{E0} Vu", "Beyonc\u{E9}", "Dangerously in Love"),
        Self.song("2", "Levitating", "Dua Lipa", "Future Nostalgia"),
        Self.song("3", "Radio", "Lana Del Rey", "Ultraviolence"),
        Self.song("4", "Houdini", "Dua Lipa", "Radical Optimism"),
    ]

    @Test func emptyQueryKeepsEverything() {
        let index = SongFilterIndex(songs: songs)
        #expect(index.matchingIndexes(for: "").count == 4)
        #expect(index.matchingIndexes(for: "   ").count == 4)
        #expect(index.filter(songs, query: "").map(\.id) == ["1", "2", "3", "4"])
    }

    @Test func ignoresCaseAndDiacritics() {
        let index = SongFilterIndex(songs: songs)
        #expect(index.filter(songs, query: "deja vu").map(\.id) == ["1"])
        #expect(index.filter(songs, query: "BEYONCE").map(\.id) == ["1"])
        #expect(index.filter(songs, query: "D\u{C9}J\u{C0}").map(\.id) == ["1"])
    }

    @Test func searchesTitleArtistAndAlbumKeepingOrder() {
        let index = SongFilterIndex(songs: songs)
        #expect(index.filter(songs, query: "dua").map(\.id) == ["2", "4"])
        #expect(index.filter(songs, query: "ultra").map(\.id) == ["3"])
        #expect(index.filter(songs, query: "rad").map(\.id) == ["3", "4"])
    }

    @Test func everyWordMustMatchAnywhere() {
        let index = SongFilterIndex(songs: songs)
        #expect(index.filter(songs, query: "dua radical").map(\.id) == ["4"])
        #expect(index.filter(songs, query: "dua ultra").isEmpty)
    }

    @Test func noMatchesIsEmpty() {
        let index = SongFilterIndex(songs: songs)
        #expect(index.filter(songs, query: "zzzz").isEmpty)
    }

    @Test func aLargeListFiltersCorrectly() {
        var big: [Song] = []
        for i in 0..<20_000 {
            big.append(Self.song("s\(i)", "Song \(i)", "Artist \(i % 50)", "Album \(i % 400)"))
        }
        let index = SongFilterIndex(songs: big)
        #expect(index.count == 20_000)
        #expect(index.matchingIndexes(for: "song 19999") == [19999])
        #expect(index.matchingIndexes(for: "zzz").isEmpty)
    }
}
