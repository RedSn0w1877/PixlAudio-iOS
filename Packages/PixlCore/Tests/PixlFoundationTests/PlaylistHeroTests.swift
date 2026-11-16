import Testing
@testable import PixlFoundation

@Suite struct PlaylistHeroTests {
    @Test func ownImageWinsThenColourThenFirstSongCover() {
        #expect(PlaylistHero.art(coverImageUri: "file:///cover.jpg", hasColourCover: true, songArt: ["https://a"])
            == .image("file:///cover.jpg"))
        #expect(PlaylistHero.art(coverImageUri: nil, hasColourCover: true, songArt: ["https://a"]) == .colour)
        // The first song that has a cover, in the playlist's order (blank and missing ones skipped).
        #expect(PlaylistHero.art(coverImageUri: "  ", hasColourCover: false, songArt: [nil, "", "https://b", "https://c"])
            == .songCover("https://b"))
        #expect(PlaylistHero.art(coverImageUri: nil, hasColourCover: false, songArt: [String?]()) == .placeholder)
    }

    @Test func artURIIsWhatThePageThemesFrom() {
        #expect(PlaylistHero.Art.image("x").uri == "x")
        #expect(PlaylistHero.Art.songCover("y").uri == "y")
        #expect(PlaylistHero.Art.colour.uri == nil)
        #expect(PlaylistHero.Art.placeholder.uri == nil)
    }

    @Test func ownerIsGeneratedOrImportedOnly() {
        #expect(PlaylistHero.owner(isAiGenerated: true, source: "LOCAL") == .taizo)
        #expect(PlaylistHero.owner(isAiGenerated: true, source: "SPOTIFY") == .taizo)
        #expect(PlaylistHero.owner(isAiGenerated: false, source: "SPOTIFY") == .spotify)
        #expect(PlaylistHero.owner(isAiGenerated: false, source: "spotify") == .spotify)
        #expect(PlaylistHero.owner(isAiGenerated: false, source: "LOCAL") == nil)
        #expect(PlaylistHero.owner(isAiGenerated: false, source: "AI") == nil)
    }

    @Test func metaLineJoinsOwnerCountAndDuration() {
        #expect(PlaylistHero.meta(owner: .taizo, songCount: 30, duration: "1 h 52 min")
            == "Made by Taizo · 30 Songs · 1 h 52 min")
        #expect(PlaylistHero.meta(owner: nil, songCount: 1, duration: "3 min") == "1 Song · 3 min")
        #expect(PlaylistHero.meta(owner: .spotify, songCount: 12, duration: "") == "From Spotify · 12 Songs")
        // An empty playlist shows no "0 min".
        #expect(PlaylistHero.meta(owner: nil, songCount: 0, duration: "0 min") == "0 Songs")
    }

    @Test func pullZonesUseTheThresholds() {
        #expect(PullToFind.zone(offset: -73) == .pulled)
        #expect(PullToFind.zone(offset: -72) == .resting)
        #expect(PullToFind.zone(offset: 0) == .resting)
        #expect(PullToFind.zone(offset: 60) == .resting)
        #expect(PullToFind.zone(offset: 61) == .scrolled)
        #expect(PullToFind.zone(offset: .nan) == .resting)
    }

    @Test func pullOpensAndScrollClosesOnlyWhenItShould() {
        #expect(PullToFind.action(entering: .pulled, isOpen: false, hasQuery: false, isEditing: false) == .open)
        // Not while reordering or removing, and not when already open.
        #expect(PullToFind.action(entering: .pulled, isOpen: false, hasQuery: false, isEditing: true) == nil)
        #expect(PullToFind.action(entering: .pulled, isOpen: true, hasQuery: false, isEditing: false) == nil)
        #expect(PullToFind.action(entering: .scrolled, isOpen: true, hasQuery: false, isEditing: false) == .close)
        // A query keeps the field (its results stay reachable).
        #expect(PullToFind.action(entering: .scrolled, isOpen: true, hasQuery: true, isEditing: false) == nil)
        #expect(PullToFind.action(entering: .resting, isOpen: true, hasQuery: false, isEditing: false) == nil)
    }
}
