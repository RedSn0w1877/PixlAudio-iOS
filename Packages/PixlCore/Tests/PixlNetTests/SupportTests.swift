import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

@Suite("PixlNet support (encoding, org.json, text)")
struct SupportTests {
    @Test func androidAndOkHttpEncodings() {
        #expect(URLCoding.androidEncode("a b+c/d?e=f&g~h'(i)*!-_.é") == "a%20b%2Bc%2Fd%3Fe%3Df%26g~h'(i)*!-_.%C3%A9")
        #expect(URLCoding.okHttpQueryComponent("a b+c/d?e=f&g~h'(i)*!-_.é") == "a%20b%2Bc%2Fd%3Fe%3Df%26g%7Eh%27%28i%29*%21-_.%C3%A9")
        #expect(URLCoding.formComponent("a b+c") == "a+b%2Bc")
        #expect(URLCoding.pathSegment("a b~") == "a%20b~")
        #expect(URLCoding.androidDecode("a%20b+c%e2%82%ac%zz%") == "a b+c€%zz%")
        #expect(URLCoding.percentDecode("a+b", plusAsSpace: true) == "a b")
        #expect(URLCoding.url("https://h/p", query: [("a", "1"), ("b", nil), ("c", "x y")]) == "https://h/p?a=1&c=x%20y")
        #expect(URLCoding.url("https://h/p?k=v", query: [("a", "1")]) == "https://h/p?k=v&a=1")
        #expect(URLCoding.url("https://h/p", query: []) == "https://h/p")
        #expect(String(decoding: URLCoding.formBody([("k", "v 1"), ("x", "&")]), as: UTF8.self) == "k=v+1&x=%26")
    }

    @Test func androidQueryHandling() {
        #expect(URLCoding.androidAppendingQueryParameter("https://h/p", "k", "v") == "https://h/p?k=v")
        #expect(URLCoding.androidAppendingQueryParameter("https://h/p?", "k", "v") == "https://h/p?k=v")
        #expect(URLCoding.androidAppendingQueryParameter("https://h/p?a=1#f", "k", "v w") == "https://h/p?a=1&k=v%20w#f")
        #expect(URLCoding.androidQueryParameter("https://h/p?a=1&b=x+y&a=2", "a") == "1")
        #expect(URLCoding.androidQueryParameter("https://h/p?a=1&b=x+y", "b") == "x y")
        #expect(URLCoding.androidQueryParameter("https://h/p?flag&a=1", "flag") == "")
        #expect(URLCoding.androidQueryParameter("https://h/p", "a") == nil)
        #expect(URLCoding.rawQuery("https://h/p?a=1#x?y") == "a=1")
    }

    @Test func urlParts() {
        #expect(URLCoding.host("https://user:pw@Sub.Example.com:8443/p?q#f") == "Sub.Example.com")
        #expect(URLCoding.host("http://[::1]:80/x") == "[::1]")
        #expect(URLCoding.host("https://h") == "h" && URLCoding.host("nohost") == nil && URLCoding.host("https:///p") == nil)
        #expect(URLCoding.scheme("HTTPS://h") == "https" && URLCoding.scheme("pixlaudio://cb") == "pixlaudio" && URLCoding.scheme("1x://h") == nil)
        #expect(URLCoding.userInfo("https://u@h/p") == "u" && URLCoding.userInfo("https://h/p@x") == nil)
    }

    @Test func orgJsonCoercions() throws {
        let o = try #require(OrgJSON.object(#"{"s":"txt","n":5,"big":12345678901,"d":1.50,"e":1e3,"t":true,"null":null,"ns":"42","fs":" 7.9 ","arr":[1],"obj":{"a":"/"},"dup":1,"x":0,"dup":2}"#))
        #expect(OrgJSON.optString(o, "s") == "txt" && OrgJSON.optString(o, "n") == "5" && OrgJSON.optString(o, "big") == "12345678901")
        #expect(OrgJSON.optString(o, "d") == "1.5" && OrgJSON.optString(o, "e") == "1000.0" && OrgJSON.optString(o, "t") == "true")
        #expect(OrgJSON.optString(o, "null") == "null" && OrgJSON.optString(o, "missing") == "" && OrgJSON.optString(o, "missing", "fb") == "fb")
        #expect(OrgJSON.optString(o, "arr") == "[1]" && OrgJSON.optString(o, "obj") == #"{"a":"/"}"#)
        #expect(OrgJSON.optInt(o, "n") == 5 && OrgJSON.optInt(o, "ns") == 42 && OrgJSON.optInt(o, "fs") == 7 && OrgJSON.optInt(o, "d") == 1)
        #expect(OrgJSON.optInt(o, "big") == Int(Int32(truncatingIfNeeded: Int64(12_345_678_901))))
        #expect(OrgJSON.optInt(o, "s", -1) == -1 && OrgJSON.optInt(o, "null", -1) == -1 && OrgJSON.optInt(o, "t", 3) == 3)
        #expect(OrgJSON.optLong(o, "big") == 12_345_678_901 && OrgJSON.optLong(o, "e") == 1000)
        #expect(OrgJSON.optBoolean(o, "t") && !OrgJSON.optBoolean(o, "s") && OrgJSON.optBoolean(o, "missing", true))
        #expect(OrgJSON.has(o, "null") && !OrgJSON.has(o, "missing"))
        #expect(OrgJSON.members(o).map(\.key) == ["s", "n", "big", "d", "e", "t", "null", "ns", "fs", "arr", "obj", "dup", "x"])
        #expect(OrgJSON.members(o).first { $0.key == "dup" }?.value == .number("2"))
        #expect(OrgJSON.object("[1]") == nil && OrgJSON.parse("{bad") == nil)
    }

    @Test func orgJsonWriterEscapesLikeAndroid() {
        var o = JSONObject()
        o.append("k", .string("a/b\"c\\d\u{2028}\u{01}\té"))
        o.append("n", .integer(3))
        o.append("dup", .bool(false))
        o.append("dup", .null)
        #expect(OrgJSONWriter.write(.object(o)) == #"{"k":"a\/b\"c\\d\u2028\u0001\té","n":3,"dup":null}"#)
        #expect(OrgJSONWriter.quote("x/y") == #""x\/y""#)
    }

    @Test func javaNumberFormatting() {
        #expect(NetText.javaDoubleString(0.7) == "0.7")
        #expect(NetText.javaDoubleString(Double(Float(0.7))) == "0.699999988079071")
        #expect(NetText.javaDoubleString(1) == "1.0" && NetText.javaDoubleString(-0.0) == "-0.0" && NetText.javaDoubleString(0) == "0.0")
        #expect(NetText.javaDoubleString(1e7) == "1.0E7" && NetText.javaDoubleString(1234567.0) == "1234567.0")
        #expect(NetText.javaDoubleString(0.001) == "0.001" && NetText.javaDoubleString(0.0001) == "1.0E-4")
        #expect(NetText.javaDoubleString(Double(Float(1e-5))) == "9.999999747378752E-6")
        #expect(NetText.javaDoubleString(123456789.125) == "1.23456789125E8")
        #expect(NetText.javaDoubleString(.nan) == "NaN" && NetText.javaDoubleString(-.infinity) == "-Infinity")
        #expect(NetText.javaFloatString(0.95) == "0.95")
    }

    @Test func kotlinTextHelpers() {
        #expect(NetText.lowercased("ΟΔΟΣ ΣΑΣ") == "οδος σας")
        #expect(NetText.lowercased("ΣΑ") == "σα")
        #expect(NetText.equalsIgnoreCase("song", "SONG") && !NetText.equalsIgnoreCase("song", "songs"))
        #expect(NetText.containsIgnoreCase("1.2M Views", "views") && NetText.hasPrefixIgnoreCase("Gemini-x", "gemini"))
        #expect(NetText.substringBefore("A, B", ",") == "A" && NetText.substringBefore("A", ",") == "A")
        #expect(NetText.take("a🎵b", 2) != "a🎵" && NetText.take("abc", 5) == "abc" && NetText.length("🎵") == 2)
        #expect(NetText.toLong("+12") == 12 && NetText.toLong("-9223372036854775808") == Int64.min && NetText.toLong("9223372036854775808") == nil)
        #expect(NetText.toInt("2147483648") == nil && NetText.toLong("١٢") == 12 && NetText.toLong("") == nil && NetText.toLong("-") == nil)
        #expect(NetText.removeSuffix("novavevo", "vevo") == "nova" && NetText.removePrefix("models/x", "models/") == "x")
        #expect(NetText.containsExact("e\u{301}", "e") && !NetText.same("é", "e\u{301}"))
        #expect(NetText.indexOf("abcabc", "c", from: 3) == 5 && NetText.indexOf("a", "") == 0)
        #expect(NetText.base64URL([0xFB, 0xFF]) == "-_8" && NetText.hex([0, 255]) == "00ff")
    }

    @Test func kotlinTrimIndent() {
        #expect(KotlinIndent.trimIndent("\n    a\n      b\n    ") == "a\n  b")
        #expect(KotlinIndent.trimIndent("\n    a\nb\n") == "    a\nb")
        #expect(KotlinIndent.trimIndent("x\n  y") == "x\n  y")
        #expect(KotlinIndent.trimIndent("\n\n    a\n\n    b\n  ") == "\na\n\nb")
        #expect(KotlinIndent.lines("a\r\nb\rc\n") == ["a", "b", "c", ""])
    }

    @Test func httpValues() {
        var request = HTTPRequest(url: "https://h", headers: [HTTPHeader("A", "1"), HTTPHeader("a", "2")])
        #expect(request.header("A") == "2")
        request.setHeader("A", "3")
        #expect(request.headers == [HTTPHeader("A", "3")])
        request.addHeader("B", "x")
        #expect(request.headers.count == 2 && request.bodyText == nil)
        let response = HTTPResponse(statusCode: 204, headers: [HTTPHeader("Content-Type", "a")], text: "hé")
        #expect(response.isSuccessful && response.header("content-type") == "a" && response.text == "hé")
        #expect(!HTTPResponse(statusCode: 302).isSuccessful)
        #expect(HTTPTransportError(kind: "K", message: "m").description == "K: m")
        let urlRequest = URLSessionHTTPClient.makeURLRequest(HTTPRequest(method: .post, url: "https://example.com/p?q=1",
                                                                         headers: [HTTPHeader("X-A", "1")], body: Data("b".utf8), timeout: 9))
        #expect(urlRequest?.httpMethod == "POST" && urlRequest?.value(forHTTPHeaderField: "X-A") == "1" && urlRequest?.timeoutInterval == 9)
        #expect(urlRequest?.httpBody == Data("b".utf8))
    }
}

@Suite("Cloud stream security")
struct CloudStreamSecurityTests {
    @Test func idValidation() {
        #expect(CloudStreamSecurity.validateSpotifyTrackId("4uLU6hMCjMI75M1A2tKUQC"))
        #expect(!CloudStreamSecurity.validateSpotifyTrackId("4uLU6hMCjMI75M1A2tKUQ") && !CloudStreamSecurity.validateSpotifyTrackId("4uLU6hMCjMI75M1A2tKUQ_"))
        #expect(CloudStreamSecurity.validateYouTubeVideoId("dQw4w9WgXcQ") && CloudStreamSecurity.validateYouTubeVideoId("a-b_c-d_e-f"))
        #expect(!CloudStreamSecurity.validateYouTubeVideoId("dQw4w9WgXc") && !CloudStreamSecurity.validateYouTubeVideoId("dQw4w9WgXc!"))
    }

    @Test func rangeHeaders() {
        #expect(CloudStreamSecurity.validateRangeHeader(nil) == .init(isValid: true))
        #expect(CloudStreamSecurity.validateRangeHeader(" bytes=0-1 ") == .init(isValid: true, normalizedHeader: "bytes=0-1", startInclusive: 0, endInclusive: 1))
        #expect(CloudStreamSecurity.validateRangeHeader("bytes=100-") == .init(isValid: true, normalizedHeader: "bytes=100-", startInclusive: 100))
        #expect(CloudStreamSecurity.validateRangeHeader("bytes=-500") == .init(isValid: true, normalizedHeader: "bytes=-500", endInclusive: 500, isSuffixRange: true))
        for bad in ["bytes=-0", "bytes=-", "items=0-1", "bytes=0-1,2-3", "bytes=1-0", "bytes=0-1-2", "bytes=a-1", "bytes=9999999999999-",
                    "bytes=0-" + String(repeating: "1", count: 70)] {
            #expect(!CloudStreamSecurity.validateRangeHeader(bad).isValid, "\(bad)")
        }
    }

    @Test func contentChecks() {
        #expect(CloudStreamSecurity.isSupportedAudioContentType(nil) && CloudStreamSecurity.isSupportedAudioContentType("Audio/MP4; codecs=x"))
        #expect(CloudStreamSecurity.isSupportedAudioContentType("video/mp4") && !CloudStreamSecurity.isSupportedAudioContentType("text/html"))
        #expect(CloudStreamSecurity.isAcceptableContentLength(nil) && CloudStreamSecurity.isAcceptableContentLength("2147483648"))
        #expect(!CloudStreamSecurity.isAcceptableContentLength("2147483649") && !CloudStreamSecurity.isAcceptableContentLength("-1")
                && !CloudStreamSecurity.isAcceptableContentLength("x"))
        #expect(CloudStreamSecurity.proxyStatus(forUpstream: 416) == 416 && CloudStreamSecurity.proxyStatus(forUpstream: 500) == 502
                && CloudStreamSecurity.proxyStatus(forUpstream: 302) == 502)
    }

    @Test func safeRemoteURLs() {
        let allowed = CloudStreamSecurity.allowedHostSuffixes(pipedTrustedHosts: ["pipedproxy.example.org"])
        #expect(CloudStreamSecurity.isSafeRemoteStreamURL("https://rr1---sn-abc.googlevideo.com/videoplayback?x", allowedHostSuffixes: allowed))
        #expect(CloudStreamSecurity.isSafeRemoteStreamURL("https://pipedproxy.example.org/videoplayback", allowedHostSuffixes: allowed))
        #expect(!CloudStreamSecurity.isSafeRemoteStreamURL("https://evilgooglevideo.com/x", allowedHostSuffixes: allowed))
        #expect(!CloudStreamSecurity.isSafeRemoteStreamURL("http://rr1.googlevideo.com/x", allowedHostSuffixes: allowed))
        #expect(CloudStreamSecurity.isSafeRemoteStreamURL("http://rr1.googlevideo.com/x", allowedHostSuffixes: allowed, allowHttpForAllowedHosts: true))
        #expect(!CloudStreamSecurity.isSafeRemoteStreamURL("https://user@rr1.googlevideo.com/x", allowedHostSuffixes: allowed))
        for local in ["https://localhost/x", "https://127.0.0.1/x", "https://10.0.0.5/x", "https://192.168.1.2/x", "https://printer.local/x", "https://[::1]/x"] {
            #expect(!CloudStreamSecurity.isSafeRemoteStreamURL(local), "\(local)")
        }
        #expect(CloudStreamSecurity.isSafeRemoteStreamURL("https://example.com/x"))
        #expect(!CloudStreamSecurity.isSafeRemoteStreamURL("ftp://example.com/x") && !CloudStreamSecurity.isSafeRemoteStreamURL("not a url"))
    }

    @Test func localHosts() {
        for host in ["localhost", "nas.lan", "box.home.arpa", "10.1.2.3", "100.64.0.1", "[fe80::1]", "fd00::1", "router"] {
            #expect(CloudStreamSecurity.isLocalOrPrivateHost(host), "\(host)")
        }
        for host in ["example.com", "8.8.8.8", "100.128.0.1", "2001:db8::1", ""] {
            #expect(!CloudStreamSecurity.isLocalOrPrivateHost(host), "\(host)")
        }
        #expect(CloudStreamSecurity.isPrivateIPv4Literal("172.31.0.1") && !CloudStreamSecurity.isPrivateIPv4Literal("172.32.0.1")
                && !CloudStreamSecurity.isPrivateIPv4Literal("1.2.3"))
    }
}
