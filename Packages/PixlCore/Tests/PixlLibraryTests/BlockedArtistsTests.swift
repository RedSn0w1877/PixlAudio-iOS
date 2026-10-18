import Foundation
import Testing
import PixlModel
@testable import PixlLibrary

@Suite struct BlockedArtistsTests {
    private func song(_ id: String, title: String = "T", artist: String, artistId: Int64 = 1,
                      artists: [ArtistRef] = [], album: String = "A") -> Song {
        Song(id: id, title: title, artist: artist, artistId: artistId, artists: artists, album: album, albumId: 1,
             path: "", contentUriString: "", albumArtUriString: nil, duration: 1000, mimeType: nil, bitrate: nil,
             sampleRate: nil)
    }

    @Test func foldingIgnoresCaseDiacriticsAndSpacing() {
        #expect(SearchFolding.fold("  BEYONC\u{C9}   Knowles ") == "beyonce knowles")
        #expect(SearchFolding.fold("Sigur R\u{F3}s") == "sigur ros")
        #expect(SearchFolding.fold("") == "")
    }

    @Test func idMatchesFirst() {
        let matcher = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 42, name: "Someone")])
        #expect(matcher.isBlocked(song("1", artist: "Other", artistId: 42)))
        #expect(!matcher.isBlocked(song("2", artist: "Other", artistId: 43)))
    }

    @Test func nameFallbackCatchesMatcherCreatedArtistsWithOtherIds() {
        let matcher = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 42, name: "Beyonc\u{E9}")])
        let credited = song("1", artist: "x", artistId: 9, artists: [ArtistRef(id: 777, name: "BEYONCE", isPrimary: true)])
        #expect(matcher.isBlocked(credited))
    }

    @Test func anyCreditedArtistBlocksTheSong() {
        let matcher = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 5, name: "Feature Guy")])
        let refs = [ArtistRef(id: 1, name: "Main", isPrimary: true), ArtistRef(id: 5, name: "Feature Guy")]
        let featured = song("1", artist: "Main", artistId: 1, artists: refs)
        #expect(matcher.isBlocked(featured))
        #expect(matcher.blockedArtists(of: featured).map(\.name) == ["Feature Guy"])
    }

    @Test func unknownIdsAndEmptyNamesNeverMatch() {
        let matcher = BlockedArtistMatcher(entries: [BlockedArtist(artistId: -1, name: "  ")])
        #expect(!matcher.isBlocked(song("1", artist: "", artistId: -1)))
        #expect(!matcher.isBlocked(Song.emptySong()))
    }

    @Test func allowedKeepsOrder() {
        let matcher = BlockedArtistMatcher(entries: [BlockedArtist(artistId: 2, name: "B")])
        let songs = [song("1", artist: "A", artistId: 1), song("2", artist: "B", artistId: 2),
                     song("3", artist: "C", artistId: 3)]
        #expect(matcher.allowed(songs).map(\.id) == ["1", "3"])
        #expect(BlockedArtistMatcher.empty.allowed(songs).count == 3)
    }

    @Test func addingAndRemoving() {
        var matcher = BlockedArtistMatcher.empty
        matcher = matcher.adding(BlockedArtist(artistId: 1, name: "Foo"))
        matcher = matcher.adding(BlockedArtist(artistId: 99, name: "foo"))
        #expect(matcher.count == 1)
        matcher = matcher.adding(BlockedArtist(artistId: 2, name: "Bar"))
        #expect(matcher.count == 2)
        matcher = matcher.removing(artistId: 7, name: "FOO")
        #expect(matcher.entries.map(\.name) == ["Bar"])
    }

    @Test func codecRoundTripsSortsAndDropsDuplicates() {
        let text = BlockedArtistCodec.encode([BlockedArtist(artistId: 2, name: "Zed", blockedAt: 5),
                                              BlockedArtist(artistId: 1, name: "alpha", blockedAt: 6)])
        let back = BlockedArtistCodec.decode(text)
        #expect(back.map(\.name) == ["alpha", "Zed"])
        #expect(BlockedArtistCodec.decode("not json").isEmpty)
        #expect(BlockedArtistCodec.decode(nil).isEmpty)
        let dup = BlockedArtistCodec.encode([BlockedArtist(artistId: 1, name: "A"), BlockedArtist(artistId: 2, name: "a")])
        #expect(BlockedArtistCodec.decode(dup).count == 1)
    }

    @Test func nextSkipsBlockedAndStopsAtTheEnd() {
        let blocked: Set<Int> = [1, 2]
        #expect(BlockedNavigation.next(after: 0, count: 5, wraps: false, isBlocked: blocked.contains) == 3)
        #expect(BlockedNavigation.next(after: 3, count: 4, wraps: false, isBlocked: blocked.contains) == nil)
        #expect(BlockedNavigation.next(after: 3, count: 4, wraps: true, isBlocked: blocked.contains) == 0)
    }

    @Test func nextIsNilWhenEverythingElseIsBlocked() {
        let all: Set<Int> = [0, 1, 2]
        #expect(BlockedNavigation.next(after: 0, count: 3, wraps: true, isBlocked: all.contains) == nil)
        let others: Set<Int> = [1, 2]
        #expect(BlockedNavigation.next(after: 0, count: 3, wraps: true, isBlocked: others.contains) == 0)
    }

    @Test func previousSkipsBlockedAndWraps() {
        let blocked: Set<Int> = [2, 3]
        #expect(BlockedNavigation.previous(before: 4, count: 5, wraps: false, isBlocked: blocked.contains) == 1)
        #expect(BlockedNavigation.previous(before: 0, count: 5, wraps: false, isBlocked: blocked.contains) == nil)
        #expect(BlockedNavigation.previous(before: 0, count: 5, wraps: true, isBlocked: blocked.contains) == 4)
    }

    @Test func firstPlayableStartsAtTheNearestAllowedSong() {
        let blocked: Set<Int> = [0, 1]
        #expect(BlockedNavigation.firstPlayable(from: 0, count: 4, isBlocked: blocked.contains) == 2)
        #expect(BlockedNavigation.firstPlayable(from: 3, count: 4, isBlocked: blocked.contains) == 3)
        let all: Set<Int> = [0, 1]
        #expect(BlockedNavigation.firstPlayable(from: 0, count: 2, isBlocked: all.contains) == nil)
        #expect(BlockedNavigation.firstPlayable(from: 0, count: 0, isBlocked: { _ in false }) == nil)
    }
}
