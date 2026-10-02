import Foundation
import Testing
@testable import PixlNet

/// Android `ArtistImageRepository`: the Deezer request, the picture order and the high-resolution upgrade.
@Suite("Deezer artist images")
struct DeezerArtistImagesTests {
    @Test func searchRequestEncodesTheNameLikeRetrofit() {
        let request = DeezerArtistImages.searchRequest(artistName: "Sigur Rós & Friends")
        #expect(request.method == .get)
        #expect(request.url == "https://api.deezer.com/search/artist?q=Sigur%20R%C3%B3s%20%26%20Friends&limit=1")
    }

    @Test func picksTheLargestPictureAndUpgradesIt() {
        let body = #"""
        {"data":[{"id":27,"name":"Daft Punk",
          "picture":"https://api.deezer.com/artist/27/image",
          "picture_medium":"https://e-cdns-images.dzcdn.net/images/artist/f2bc0/250x250-000000-80-0-0.jpg",
          "picture_big":"https://e-cdns-images.dzcdn.net/images/artist/f2bc0/500x500-000000-80-0-0.jpg",
          "picture_xl":"https://e-cdns-images.dzcdn.net/images/artist/f2bc0/1000x1000-000000-80-0-0.jpg"}],"total":1}
        """#
        #expect(DeezerArtistImages.outcome(statusCode: 200, body: Data(body.utf8))
                == .picture("https://e-cdns-images.dzcdn.net/images/artist/f2bc0/1000x1000-000000-80-0-0.jpg"))
        let noXl = #"{"data":[{"picture_xl":null,"picture_big":"https://e-cdns-images.dzcdn.net/images/artist/a/500x500-000000-80-0-0.jpg"}]}"#
        #expect(DeezerArtistImages.outcome(statusCode: 200, body: Data(noXl.utf8))
                == .picture("https://e-cdns-images.dzcdn.net/images/artist/a/1000x1000-000000-80-0-0.jpg"))
    }

    @Test func noMatchAndErrors() {
        #expect(DeezerArtistImages.outcome(statusCode: 200, body: Data(#"{"data":[],"total":0}"#.utf8)) == .noMatch)
        #expect(DeezerArtistImages.outcome(statusCode: 200, body: Data(#"{"data":[{"name":"x"}]}"#.utf8)) == .noMatch)
        let quota = #"{"error":{"type":"Exception","message":"Quota limit exceeded","code":4}}"#
        #expect(DeezerArtistImages.outcome(statusCode: 200, body: Data(quota.utf8)) == .failed)
        #expect(DeezerArtistImages.outcome(statusCode: 503, body: Data()) == .failed)
        #expect(DeezerArtistImages.outcome(statusCode: 200, body: Data("<html>".utf8)) == .failed)
    }

    @Test func upgradeOnlyTouchesDeezerArtistPictures() {
        #expect(DeezerArtistImages.upgradeToHighRes("https://cdn-images.dzcdn.net/images/artist/abc/56x56-000000-80-0-0.jpg")
                == "https://cdn-images.dzcdn.net/images/artist/abc/1000x1000-000000-80-0-0.jpg")
        #expect(DeezerArtistImages.upgradeToHighRes("https://cdn-images.dzcdn.net/images/cover/abc/56x56-000000-80-0-0.jpg")
                == "https://cdn-images.dzcdn.net/images/cover/abc/56x56-000000-80-0-0.jpg")
        #expect(DeezerArtistImages.upgradeToHighRes("https://example.com/250x250.jpg") == "https://example.com/250x250.jpg")
        #expect(DeezerArtistImages.normalizedName("  Daft PUNK ") == "daft punk")
    }
}
