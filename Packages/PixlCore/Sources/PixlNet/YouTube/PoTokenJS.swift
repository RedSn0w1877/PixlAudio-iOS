// Port of `data/youtube/potoken/JavaScriptUtil.kt` (itself NewPipe's `util/potoken/JavaScriptUtil.kt`) and the
// BotGuard service requests of `PoTokenWebView.kt`. BotGuard runs inside a web view (the app's off-screen
// WKWebView with `po_token.html`); everything around it is plain data handling and lives here so it is tested on
// Windows: the `Create` / `GenerateIT` requests, the challenge descrambling, the integrity token and the
// Uint8Array ↔ URL-safe base64 conversions.

import Foundation
import PixlFoundation

/// BotGuard / PoToken helpers.
public enum PoTokenJS {
    /// Public BotGuard API key (seen in every request of YouTube's web player; not a secret of this app).
    public static let googleAPIKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    public static let requestKey = "O43z0dpjhgX20SCx4KAo"
    /// The browser identity the web view and the BotGuard requests use.
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3"
    public static let createURL = "https://www.youtube.com/api/jnn/v1/Create"
    public static let generateITURL = "https://www.youtube.com/api/jnn/v1/GenerateIT"
    /// The page's base URL (the HTML is loaded with this origin, as on Android).
    public static let pageBaseURL = "https://www.youtube.com"
    /// Tokens are not served within this many seconds of the integrity token's expiry (10 minutes on Android).
    public static let expiryMarginSeconds: Int64 = 600

    // MARK: Requests

    /// `makeBotguardServiceRequest(url, data)`: a POST with the BotGuard headers. OkHttp sends the body's media type
    /// (`application/json+protobuf; charset=utf-8`) as the Content-Type.
    public static func serviceRequest(url: String, body: String) -> HTTPRequest {
        var request = HTTPRequest(method: .post, url: url, body: Data(body.utf8), timeout: 20)
        request.setHeader("User-Agent", userAgent)
        request.setHeader("Accept", "application/json")
        request.setHeader("Content-Type", "application/json+protobuf; charset=utf-8")
        request.setHeader("x-goog-api-key", googleAPIKey)
        request.setHeader("x-user-agent", "grpc-web-javascript/0.1")
        return request
    }

    /// Step 1: `Create` — the challenge (interpreter + program) to run.
    public static func createRequest() -> HTTPRequest {
        serviceRequest(url: createURL, body: "[ \(JSONWriter.write(.string(requestKey))) ]")
    }

    /// Step 2: `GenerateIT` — trades BotGuard's response for the integrity token.
    public static func generateITRequest(botguardResponse: String) -> HTTPRequest {
        serviceRequest(url: generateITURL,
                       body: "[ \(JSONWriter.write(.string(requestKey))), \(JSONWriter.write(.string(botguardResponse))) ]")
    }

    // MARK: Parsing

    /// Why a BotGuard step could not be parsed.
    public struct ParseError: Error, Sendable, Hashable, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    /// `parseChallengeData`: the `Create` response (scrambled or not) → the JSON object `runBotGuard(data)` takes:
    /// `messageId`, `interpreterJavascript{privateDoNotAccessOrElseSafeScriptWrappedValue,
    /// privateDoNotAccessOrElseTrustedResourceUrlWrappedValue}`, `interpreterHash`, `program`, `globalName`,
    /// `clientExperimentsStateBlob` (missing values are `null`).
    public static func parseChallengeData(_ raw: String) throws(ParseError) -> String {
        guard let scrambled = OrgJSON.parse(raw)?.arrayValue else { throw ParseError("Create: not a JSON array") }
        let challenge: [JSONValue]
        if scrambled.count > 1, case .string(let text) = scrambled[1] {
            let descrambled = try descramble(text)
            guard let array = OrgJSON.parse(descrambled)?.arrayValue else {
                throw ParseError("Create: the descrambled challenge is not a JSON array")
            }
            challenge = array
        } else {
            guard let first = scrambled.first?.arrayValue else { throw ParseError("Create: no challenge array") }
            challenge = first
        }

        func string(_ index: Int) -> JSONValue {
            guard index < challenge.count, case .string(let s) = challenge[index] else { return .null }
            return .string(s)
        }
        func firstString(inArrayAt index: Int) -> JSONValue {
            guard index < challenge.count, let array = challenge[index].arrayValue else { return .null }
            for item in array { if case .string(let s) = item { return .string(s) } }
            return .null
        }

        var interpreter = JSONObject()
        interpreter.append("privateDoNotAccessOrElseSafeScriptWrappedValue", firstString(inArrayAt: 1))
        interpreter.append("privateDoNotAccessOrElseTrustedResourceUrlWrappedValue", firstString(inArrayAt: 2))
        var out = JSONObject()
        out.append("messageId", string(0))
        out.append("interpreterJavascript", .object(interpreter))
        out.append("interpreterHash", string(3))
        out.append("program", string(4))
        out.append("globalName", string(5))
        out.append("clientExperimentsStateBlob", string(7))
        return JSONWriter.write(.object(out))
    }

    /// `parseIntegrityTokenData`: the `GenerateIT` response → the integrity token's bytes and its lifetime (s).
    public static func parseIntegrityTokenData(_ raw: String) throws(ParseError) -> (token: [UInt8], expiresInSeconds: Int64) {
        guard let array = OrgJSON.parse(raw)?.arrayValue, array.count > 1, case .string(let base64) = array[0],
              let lifetime = OrgJSON.int(array[1]).map(Int64.init) ?? array[1].int64Value else {
            throw ParseError("GenerateIT: unexpected response")
        }
        return (try base64ToBytes(base64), lifetime)
    }

    // MARK: Conversions

    /// `descramble`: base64 (URL-safe, `.` padding) → every byte + 97 → UTF-8.
    public static func descramble(_ scrambled: String) throws(ParseError) -> String {
        let bytes = try base64ToBytes(scrambled).map { $0 &+ 97 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `base64ToByteString`: `-`→`+`, `_`→`/`, `.`→`=`, then base64 (padding optional, like okio).
    public static func base64ToBytes(_ base64: String) throws(ParseError) -> [UInt8] {
        var text = base64.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: ".", with: "=")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("=") { text.removeLast() }
        let remainder = text.utf8.count % 4
        if remainder == 1 { throw ParseError("Cannot base64 decode") }
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: text) else { throw ParseError("Cannot base64 decode") }
        return Array(data)
    }

    /// `newUint8Array(bytes)`: the JavaScript literal `new Uint8Array([97,98,99])`.
    public static func uint8ArrayLiteral(_ bytes: [UInt8]) -> String {
        "new Uint8Array([" + bytes.map { String($0) }.joined(separator: ",") + "])"
    }

    /// `stringToU8(identifier)`: the identifier's UTF-8 bytes as a `Uint8Array` literal.
    public static func stringToU8(_ identifier: String) -> String { uint8ArrayLiteral(Array(identifier.utf8)) }

    /// `u8ToBase64`: a token's bytes → standard base64 with `+`→`-` and `/`→`_` (padding kept), YouTube's form.
    public static func bytesToBase64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// `u8ToBase64(poToken)`: JavaScript's `Uint8Array.toString()` ("97,98,99") → the token. nil when a value is not
    /// a byte.
    public static func u8StringToBase64URL(_ text: String) -> String? {
        var bytes: [UInt8] = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard let value = UInt8(part.trimmingCharacters(in: .whitespaces)) else { return nil }
            bytes.append(value)
        }
        return bytesToBase64URL(bytes)
    }

    /// Whether a generator created with an integrity token of `lifetimeSeconds` at `createdAtSeconds` is expired at
    /// `nowSeconds` (served until 10 minutes before the real expiry).
    public static func isExpired(createdAtSeconds: Int64, lifetimeSeconds: Int64, nowSeconds: Int64) -> Bool {
        nowSeconds > createdAtSeconds + lifetimeSeconds - expiryMarginSeconds
    }
}
