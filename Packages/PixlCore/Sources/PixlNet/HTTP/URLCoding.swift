// URL and form encoding exactly as the Android code produced it: `android.net.Uri.encode/decode` and
// `Uri.Builder.appendQueryParameter`, OkHttp's `HttpUrl.Builder.addQueryParameter` (Retrofit `@Query`), and
// OkHttp's `FormBody` (Retrofit `@FormUrlEncoded`).

import Foundation

/// URL/query encoding helpers.
public enum URLCoding {
    // MARK: Percent encoding

    private static let hexDigits: [Character] = Array("0123456789ABCDEF")

    private static func percentEncode(_ s: String, keep: (UInt8) -> Bool, spaceAsPlus: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for byte in s.utf8 {
            if spaceAsPlus && byte == 0x20 {
                out.append("+")
            } else if keep(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out.append("%")
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    private static func isAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    /// `android.net.Uri.encode(s)`: keeps letters, digits and `_-!.~'()*`; everything else is UTF-8 `%XX`.
    public static func androidEncode(_ s: String) -> String {
        percentEncode(s) { b in isAlnum(b) || "_-!.~'()*".utf8.contains(b) }
    }

    /// `android.net.Uri.decode(s)`: `%XX` sequences decoded as UTF-8 (malformed bytes become U+FFFD), `+` kept.
    public static func androidDecode(_ s: String) -> String { percentDecode(s, plusAsSpace: false) }

    /// Decodes `%XX` escapes (and `+` when `plusAsSpace`). Invalid escapes are kept literally.
    public static func percentDecode(_ s: String, plusAsSpace: Bool) -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "%"), i + 2 < bytes.count, let h = hexValue(bytes[i + 1]), let l = hexValue(bytes[i + 2]) {
                out.append(h << 4 | l)
                i += 3
                continue
            }
            if plusAsSpace && b == UInt8(ascii: "+") {
                out.append(0x20)
            } else {
                out.append(b)
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// OkHttp `addQueryParameter` (Retrofit `@Query`): keeps letters, digits and `-._*`; space is `%20`, `+` is
    /// `%2B`, everything else UTF-8 `%XX`.
    public static func okHttpQueryComponent(_ s: String) -> String {
        percentEncode(s) { b in isAlnum(b) || "-._*".utf8.contains(b) }
    }

    /// OkHttp `FormBody` field encoding: like a query component but space becomes `+`.
    public static func formComponent(_ s: String) -> String {
        percentEncode(s, keep: { b in isAlnum(b) || "-._*".utf8.contains(b) }, spaceAsPlus: true)
    }

    /// Retrofit `@Path` segment encoding (unreserved characters kept).
    public static func pathSegment(_ s: String) -> String {
        percentEncode(s) { b in isAlnum(b) || "-._~".utf8.contains(b) }
    }

    // MARK: Builders

    /// `base` + `?name=value&…` with OkHttp query encoding (nil values are skipped, as Retrofit does).
    public static func url(_ base: String, query: [(name: String, value: String?)]) -> String {
        let items = query.compactMap { item in item.value.map { okHttpQueryComponent(item.name) + "=" + okHttpQueryComponent($0) } }
        if items.isEmpty { return base }
        return base + (base.contains("?") ? "&" : "?") + items.joined(separator: "&")
    }

    /// An `application/x-www-form-urlencoded` body (OkHttp `FormBody`).
    public static func formBody(_ fields: [(name: String, value: String)]) -> Data {
        Data(fields.map { formComponent($0.name) + "=" + formComponent($0.value) }.joined(separator: "&").utf8)
    }

    /// `Uri.parse(url).buildUpon().appendQueryParameter(key, value).build().toString()`: appends to the encoded
    /// query (before any fragment) with Android encoding.
    public static func androidAppendingQueryParameter(_ url: String, _ key: String, _ value: String) -> String {
        var base = url
        var fragment = ""
        if let hash = url.firstIndex(of: "#") {
            base = String(url[..<hash])
            fragment = String(url[hash...])
        }
        let pair = androidEncode(key) + "=" + androidEncode(value)
        if let q = base.firstIndex(of: "?") {
            let query = base[base.index(after: q)...]
            return base + (query.isEmpty ? "" : "&") + pair + fragment
        }
        return base + "?" + pair + fragment
    }

    // MARK: Parsing

    /// The raw (encoded) query of a URL, or nil without `?`.
    public static func rawQuery(_ url: String) -> String? {
        var base = Substring(url)
        if let hash = base.firstIndex(of: "#") { base = base[..<hash] }
        guard let q = base.firstIndex(of: "?") else { return nil }
        return String(base[base.index(after: q)...])
    }

    /// `Uri.getQueryParameter(name)`: the first value for a (decoded) name, decoded with `+` as space.
    public static func androidQueryParameter(_ url: String, _ name: String) -> String? {
        androidQueryParameters(url).first { $0.name == name }?.value
    }

    /// Every `name=value` pair of the query, decoded like `Uri.getQueryParameter` (`+` → space).
    public static func androidQueryParameters(_ url: String) -> [(name: String, value: String)] {
        guard let query = rawQuery(url), !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { pair -> (String, String) in
            if let eq = pair.firstIndex(of: "=") {
                return (percentDecode(String(pair[..<eq]), plusAsSpace: true),
                        percentDecode(String(pair[pair.index(after: eq)...]), plusAsSpace: true))
            }
            return (percentDecode(String(pair), plusAsSpace: true), "")
        }
    }

    /// `java.net.URI(url).host` for the http(s) URLs the ports meet: the authority without user info and port
    /// (IPv6 literals keep their brackets). nil when there is no authority.
    public static func host(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        var rest = url[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            return String(rest[...close])
        }
        if let colon = rest.firstIndex(of: ":") { rest = rest[..<colon] }
        return rest.isEmpty ? nil : String(rest)
    }

    /// The scheme of a URL (lower-cased), or nil.
    public static func scheme(_ url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.unicodeScalars.first, first.properties.isAlphabetic, first.isASCII,
              scheme.unicodeScalars.allSatisfy({ $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || "+-.".unicodeScalars.contains($0)) })
        else { return nil }
        return scheme.lowercased()
    }

    /// The user-info part of an authority (`user:pass@`), or nil.
    public static func userInfo(_ url: String) -> String? {
        guard let schemeEnd = url.range(of: "://") else { return nil }
        var rest = url[schemeEnd.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { rest = rest[..<end] }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        return String(rest[..<at])
    }
}
