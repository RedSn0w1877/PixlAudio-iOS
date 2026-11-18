import Testing
@testable import PixlNet

/// The id rule Autoplay uses to decide whether a library pick plays on Spotify Connect with no lookup
/// (`AutoplayPolicy.isSpotifyTrackId`, PixlLibrary) is a copy of `SpotifyConnect.isTrackId`: the two cannot import each
/// other, so both are checked against the same table (`BrainRemoteOutputTests.idTable`).
@Suite("Spotify Connect track ids")
struct SpotifyConnectIdTests {
    static let table: [(String?, Bool)] = [
        ("4iV5W9uYEdYUVa79Axb7Rh", true),
        ("0123456789abcdef012345", false),
        (nil, false), ("too-short", false), ("4iV5W9uYEdYUVa79Axb7R!", false), ("", false),
        ("ABCDEFGHIJKLMNOPQRSTUV", true), ("4iV5W9uYEdYUVa79Axb7Rhh", false),
    ]

    @Test func theRuleGivesTheTablesAnswers() {
        for (id, expected) in Self.table {
            #expect(SpotifyConnect.isTrackId(id ?? "") == expected, "\(id ?? "nil")")
        }
    }
}
