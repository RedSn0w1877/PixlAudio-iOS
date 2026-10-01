// Port of `data/youtube/SignatureCipherSolver.kt`. YouTube scrambles `signatureCipher` signatures and the `n`
// parameter with functions inside the web player's base.js, which change every few weeks, so they are not
// re-implemented: PixlNet finds them in base.js with Android's patterns, extracts their source (counting braces),
// and builds the call; the app runs it with JavaScriptCore (`JavaScriptEvaluating`).

import Foundation

/// Runs a JavaScript expression and returns its string result (the app's JSContext; Android's `JsEvaluator`).
public protocol JavaScriptEvaluating: Sendable {
    func evaluate(_ script: String) async -> String?
}

/// The functions extracted from one base.js.
public struct PlayerScript: Sendable, Hashable {
    public var playerId: String
    /// Defines `__ppSig(a)` (helper object + scramble function), or nil when the patterns are outdated.
    public var signatureFunctionJs: String?
    /// Defines `__ppN(a)`, or nil when the patterns are outdated.
    public var nFunctionJs: String?

    public init(playerId: String, signatureFunctionJs: String?, nFunctionJs: String?) {
        self.playerId = playerId
        self.signatureFunctionJs = signatureFunctionJs
        self.nFunctionJs = nFunctionJs
    }
}

/// base.js extraction and URL rewriting (pure).
public enum SignatureCipher {
    public static let iframeApiURL = "https://www.youtube.com/iframe_api"

    /// The base.js URL for a player id.
    public static func baseJsURL(playerId: String) -> String {
        "https://www.youtube.com/s/player/\(playerId)/player_ias.vflset/en_US/base.js"
    }

    // MARK: Patterns (Android's, verbatim)

    static let playerIdPattern = #"player\\?/([a-zA-Z0-9_-]{8,})\\?/"#

    static let signatureNamePatterns = [
        #"\bm=([a-zA-Z0-9_$]{2,})\(decodeURIComponent\(h\.s\)\)"#,
        #"\bc&&\(c=([a-zA-Z0-9_$]{2,})\(decodeURIComponent\(c\)\)"#,
        #"(?:\b|[^a-zA-Z0-9_$])([a-zA-Z0-9_$]{2,})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*[""']{2}\s*\)"#,
        #"([a-zA-Z0-9_$]+)\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*[""']{2}\s*\);"#,
    ]

    static let nNamePatterns = [
        #"\.get\("n"\)\)&&\([a-zA-Z0-9_$]=([a-zA-Z0-9_$]+)(?:\[\d+\])?\("#,
        #"\([a-zA-Z0-9_$]=String\.fromCharCode\(110\),[a-zA-Z0-9_$]=[a-zA-Z0-9_$]\.get\([a-zA-Z0-9_$]\)\)&&\([a-zA-Z0-9_$]=([a-zA-Z0-9_$]+)(?:\[\d+\])?\("#,
        #"[a-zA-Z0-9_$]+\.set\("n",\s*([a-zA-Z0-9_$]+)\("#,
    ]

    static let helperCallPattern = #"([a-zA-Z0-9_$]{2,})\.[a-zA-Z0-9_$]{2,}\(\s*a\s*,"#

    // MARK: Extraction

    /// The player id in the iframe API script.
    public static func playerId(iframeApi: String) -> String? {
        firstGroup(playerIdPattern, in: iframeApi)
    }

    /// JavaScript defining `__ppSig(a)`: the helper object with the scramble operations plus the function chaining
    /// them. nil when no pattern finds the function.
    public static func signatureFunction(baseJs: String) -> String? {
        guard let name = signatureNamePatterns.lazy.compactMap({ firstGroup($0, in: baseJs) }).first(where: { !NetText.isBlank($0) }),
              let body = functionBody(baseJs, name: name) else { return nil }
        // The body calls a helper object: `Xy.AB(a,3); Xy.CD(a,17); …`
        let helperName = firstGroup(helperCallPattern, in: body)
        let helper = helperName.flatMap { objectLiteral(baseJs, name: $0) } ?? ""
        return "\(helper) function __ppSig(a){\(body)}"
    }

    /// JavaScript defining `__ppN(a)`. The name may be a one-element array (`var Dm=[nfn];`).
    public static func nFunction(baseJs: String) -> String? {
        guard let rawName = nNamePatterns.lazy.compactMap({ firstGroup($0, in: baseJs) }).first(where: { !NetText.isBlank($0) })
        else { return nil }
        let arrayPattern = #"var\s+"# + NSRegularExpression.escapedPattern(for: rawName) + #"\s*=\s*\[\s*([a-zA-Z0-9_$]+)\s*\]"#
        let name = firstGroup(arrayPattern, in: baseJs) ?? rawName
        guard let body = functionBody(baseJs, name: name) else { return nil }
        return "function __ppN(a){\(body)}"
    }

    /// Both functions for a base.js.
    public static func playerScript(playerId: String, baseJs: String) -> PlayerScript {
        PlayerScript(playerId: playerId, signatureFunctionJs: signatureFunction(baseJs: baseJs), nFunctionJs: nFunction(baseJs: baseJs))
    }

    /// `extractFunctionBody`: the body of `name = function(a){ … }` (or `function name(a){…}`, `name: function…`),
    /// found by counting braces — a regex cannot, the `n` body nests braces.
    public static func functionBody(_ js: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let declarations = [
            #"(?:var\s+|;|,|^)"# + escaped + #"\s*=\s*function\s*\(\s*[a-zA-Z0-9_$]*\s*\)\s*\{"#,
            #"function\s+"# + escaped + #"\s*\(\s*[a-zA-Z0-9_$]*\s*\)\s*\{"#,
            escaped + #"\s*:\s*function\s*\(\s*[a-zA-Z0-9_$]*\s*\)\s*\{"#,
        ]
        let units = Array(js.utf16)
        guard let match = declarations.lazy.compactMap({ firstMatchRange($0, in: js) }).first else { return nil }
        let last = match.location + match.length - 1
        guard let open = indexOf(units, UInt16(UInt8(ascii: "{")), from: max(last - 1, 0)),
              let close = matchingBrace(units, open) else { return nil }
        return String(decoding: units[(open + 1)..<close], as: UTF16.self)
    }

    /// `extractObjectLiteral`: `var <name> = { … };` re-emitted as a statement.
    public static func objectLiteral(_ js: String, name: String) -> String? {
        let pattern = #"var\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*\{"#
        let units = Array(js.utf16)
        guard let match = firstMatchRange(pattern, in: js) else { return nil }
        let last = match.location + match.length - 1
        guard let open = indexOf(units, UInt16(UInt8(ascii: "{")), from: max(last - 1, 0)),
              let close = matchingBrace(units, open) else { return nil }
        return "var \(name) = \(String(decoding: units[open...close], as: UTF16.self));"
    }

    /// `findMatchingBrace`: the index of the brace closing the one at `openIndex`, skipping braces inside quoted
    /// strings (`"`, `'`, `` ` ``) with backslash escapes. (Like Android, regex literals and comments are not
    /// special-cased.)
    static func matchingBrace(_ js: [UInt16], _ openIndex: Int) -> Int? {
        var depth = 0
        var index = openIndex
        var quote: UInt16?
        var escaped = false
        let backslash = UInt16(UInt8(ascii: "\\")), dq = UInt16(UInt8(ascii: "\"")), sq = UInt16(UInt8(ascii: "'")), bt = UInt16(UInt8(ascii: "`"))
        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
        while index < js.count {
            let c = js[index]
            if escaped {
                escaped = false
            } else if quote != nil && c == backslash {
                escaped = true
            } else if let q = quote, c == q {
                quote = nil
            } else if quote != nil {
                // inside a string
            } else if c == dq || c == sq || c == bt {
                quote = c
            } else if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    // MARK: Calls

    /// `(function(){ <sig fn>; return __ppSig("<s>"); })()`.
    public static func signatureCall(functionJs: String, scrambled: String) -> String {
        "(function(){ \(functionJs); return __ppSig(\(OrgJSONWriter.quote(scrambled))); })()"
    }

    /// `(function(){ <n fn>; return __ppN("<n>"); })()`.
    public static func nCall(functionJs: String, n: String) -> String {
        "(function(){ \(functionJs); return __ppN(\(OrgJSONWriter.quote(n))); })()"
    }

    // MARK: URLs

    /// The parts of a `signatureCipher` (`url=…&s=…&sp=sig`).
    public struct CipherParts: Sendable, Hashable {
        public var url: String
        /// The scrambled signature, or nil when the cipher carries a plain URL.
        public var scrambledSignature: String?
        /// The query parameter the deciphered signature goes in (`sp`, default "signature").
        public var signatureParameter: String
    }

    /// Parses a `signatureCipher` query string (values `Uri.decode`d, later duplicates win).
    public static func cipherParts(_ signatureCipher: String) -> CipherParts? {
        let params = parseQueryString(signatureCipher)
        guard let url = params["url"] else { return nil }
        return CipherParts(url: url, scrambledSignature: params["s"], signatureParameter: params["sp"] ?? "signature")
    }

    /// `parseQueryString`: pairs with a non-empty key, value `Uri.decode`d.
    static func parseQueryString(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: false) {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { continue }
            out[String(pair[..<eq])] = URLCoding.androidDecode(String(pair[pair.index(after: eq)...]))
        }
        return out
    }

    /// The base URL with the deciphered signature appended (`Uri.Builder.appendQueryParameter`).
    public static func applySignature(_ parts: CipherParts, deciphered: String) -> String {
        URLCoding.androidAppendingQueryParameter(parts.url, parts.signatureParameter, deciphered)
    }

    /// The `n` parameter of a URL (decoded), or nil.
    public static func nParameter(_ url: String) -> String? {
        URLCoding.androidQueryParameter(url, "n")
    }

    /// The URL rebuilt with a transformed `n` (Android `clearQuery` + `appendQueryParameter` for every name, first
    /// value each) — or the URL unchanged when the function gave up (`enhanced_except…`) or returned `n` itself.
    public static func applyNTransform(_ url: String, original n: String, transformed: String) -> String {
        if transformed.hasPrefix("enhanced_except") || transformed == n { return url }
        var base = url
        var fragment = ""
        if let hash = base.firstIndex(of: "#") {
            fragment = String(base[hash...])
            base = String(base[..<hash])
        }
        if let q = base.firstIndex(of: "?") { base = String(base[..<q]) }
        var names: [String] = []
        for (name, _) in URLCoding.androidQueryParameters(url) where !names.contains(name) { names.append(name) }
        var pairs: [String] = []
        for name in names {
            let value = name == "n" ? transformed : (URLCoding.androidQueryParameter(url, name) ?? "")
            pairs.append(URLCoding.androidEncode(name) + "=" + URLCoding.androidEncode(value))
        }
        return base + (pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")) + fragment
    }

    /// `withStreamingPoToken`: appends `pot=<token>` when a streaming PoToken exists.
    public static func withStreamingPoToken(_ url: String?, _ streamingPoToken: String?) -> String? {
        guard let url, let pot = streamingPoToken, !NetText.isBlank(pot) else { return url }
        return URLCoding.androidAppendingQueryParameter(url, "pot", pot)
    }

    // MARK: Regex helpers

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let r = m.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    static func firstMatchRange(_ pattern: String, in text: String) -> NSRange? {
        guard let re = regex(pattern) else { return nil }
        let ns = text as NSString
        return re.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length))?.range
    }

    private static func indexOf(_ units: [UInt16], _ c: UInt16, from start: Int) -> Int? {
        var i = start
        while i < units.count {
            if units[i] == c { return i }
            i += 1
        }
        return nil
    }
}

/// `SignatureCipherSolver`: downloads base.js once per process (cached until `invalidate`), and deciphers
/// signatures and `n` with the app's JavaScript evaluator.
public actor SignatureCipherSolver {
    private let http: any HTTPClient
    private let evaluator: any JavaScriptEvaluating
    private var cached: PlayerScript?
    private var loading: Task<PlayerScript?, Never>?

    public init(http: any HTTPClient, evaluator: any JavaScriptEvaluating) {
        self.http = http
        self.evaluator = evaluator
    }

    /// A `signatureCipher` → playable URL; nil when the decipherer could not be obtained or run.
    public func resolveCipheredUrl(_ signatureCipher: String) async -> String? {
        guard let parts = SignatureCipher.cipherParts(signatureCipher) else { return nil }
        guard let scrambled = parts.scrambledSignature else { return await applyNTransform(parts.url) }
        guard let script = await ensurePlayerScript(), let signatureJs = script.signatureFunctionJs,
              let deciphered = await evaluator.evaluate(SignatureCipher.signatureCall(functionJs: signatureJs, scrambled: scrambled))
        else { return nil }
        return await applyNTransform(SignatureCipher.applySignature(parts, deciphered: deciphered))
    }

    /// Applies the `n` transform (without it googlevideo throttles or 403s the real download).
    public func applyNTransform(_ url: String) async -> String {
        guard let n = SignatureCipher.nParameter(url), let script = await ensurePlayerScript(), let nJs = script.nFunctionJs,
              let transformed = await evaluator.evaluate(SignatureCipher.nCall(functionJs: nJs, n: n)) else { return url }
        return SignatureCipher.applyNTransform(url, original: n, transformed: transformed)
    }

    /// Drops the cached player; the next resolution downloads it again.
    public func invalidate() {
        cached = nil
    }

    /// The cached script (diagnostics).
    public var currentScript: PlayerScript? { cached }

    private func ensurePlayerScript() async -> PlayerScript? {
        if let cached { return cached }
        if let loading { return await loading.value }
        let http = self.http
        let task = Task<PlayerScript?, Never> { await Self.download(http) }
        loading = task
        let script = await task.value
        loading = nil
        cached = script
        return script
    }

    private static func get(_ http: any HTTPClient, _ url: String) async -> (status: Int?, body: String?, error: String?) {
        let request = HTTPRequest(url: url, headers: [HTTPHeader("User-Agent", InnerTubeContexts.webRemix.userAgent)])
        do {
            let response = try await http.send(request)
            return (response.statusCode, response.isSuccessful ? response.text : nil, nil)
        } catch {
            return (nil, nil, String(describing: error))
        }
    }

    private static func download(_ http: any HTTPClient) async -> PlayerScript? {
        guard let iframe = await get(http, SignatureCipher.iframeApiURL).body,
              let playerId = SignatureCipher.playerId(iframeApi: iframe),
              let baseJs = await get(http, SignatureCipher.baseJsURL(playerId: playerId)).body else { return nil }
        return SignatureCipher.playerScript(playerId: playerId, baseJs: baseJs)
    }

    /// `diagnose()`: what happened at each step (iframe, player id, base.js, patterns, a test run of `n`). A
    /// successful extraction is cached.
    public func diagnose() async -> String {
        var out = ""
        let iframe = await Self.get(http, SignatureCipher.iframeApiURL)
        out += "iframe_api: HTTP \(iframe.status.map(String.init) ?? "?") (\(iframe.body?.utf16.count ?? 0) bytes)\(iframe.error.map { " — \($0)" } ?? "")\n"
        let playerId = iframe.body.flatMap(SignatureCipher.playerId(iframeApi:))
        out += "playerId: \(playerId ?? "NOT FOUND (PLAYER_ID_REGEX didn't match)")\n"
        guard let playerId else { return out }
        let baseJsProbe = await Self.get(http, SignatureCipher.baseJsURL(playerId: playerId))
        out += "base.js: HTTP \(baseJsProbe.status.map(String.init) ?? "?") (\(baseJsProbe.body?.utf16.count ?? 0) bytes)\(baseJsProbe.error.map { " — \($0)" } ?? "")\n"
        guard let baseJs = baseJsProbe.body else { return out }
        let sig = SignatureCipher.signatureFunction(baseJs: baseJs)
        let nFn = SignatureCipher.nFunction(baseJs: baseJs)
        out += "signature function: \(sig != nil ? "found" : "NOT FOUND (outdated patterns)")\n"
        out += "n function: \(nFn != nil ? "found" : "NOT FOUND (outdated patterns)")\n"
        if let nFn {
            let result = await evaluator.evaluate(SignatureCipher.nCall(functionJs: nFn, n: "TESTVALUE123"))
            out += "run n function via JsEvaluator: \(result ?? "NULL (JsEvaluator returned nothing)")\n"
        }
        if sig != nil || nFn != nil { cached = PlayerScript(playerId: playerId, signatureFunctionJs: sig, nFunctionJs: nFn) }
        return out
    }
}
