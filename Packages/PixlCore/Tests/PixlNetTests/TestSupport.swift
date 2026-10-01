import Foundation
import Testing
import PixlFoundation
@testable import PixlNet

/// A scripted `HTTPClient`: records every request and answers with the handler (no network in tests).
final class FixtureHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    /// Answers by URL prefix (first match wins); unknown URLs get 404.
    convenience init(routes: [(prefix: String, response: HTTPResponse)]) {
        self.init { request in
            for route in routes where request.url.hasPrefix(route.prefix) { return route.response }
            return HTTPResponse(statusCode: 404, text: "")
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        return try await handler(request)
    }

    private func record(_ request: HTTPRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    var requests: [HTTPRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// Thread-safe counter/box for test closures.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

enum Fixtures {
    static func text(_ name: String, _ ext: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func json(_ name: String) throws -> JSONObject {
        try #require(try JSONParser().parse(try text(name, "json")).objectValue)
    }

    /// The golden lines for one function.
    static func golden(_ fn: String) throws -> [(input: JSONValue, output: JSONValue)] {
        let all = try goldenLines()
        return all.filter { $0.fn == fn }.map { ($0.input, $0.output) }
    }

    nonisolated(unsafe) private static var cache: [(fn: String, input: JSONValue, output: JSONValue)]?
    private static let cacheLock = NSLock()

    static func goldenLines() throws -> [(fn: String, input: JSONValue, output: JSONValue)] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache { return cache }
        let raw = try text("net-android-golden", "jsonl")
        var out: [(fn: String, input: JSONValue, output: JSONValue)] = []
        for line in raw.split(separator: "\n") where !line.isEmpty {
            let o = try #require(try JSONParser().parse(String(line)).objectValue)
            out.append((try #require(o["fn"]?.stringValue), o["in"] ?? .null, o["out"] ?? .null))
        }
        cache = out
        return out
    }
}

/// SHA-256 (FIPS 180-4) for tests; the app injects CryptoKit's.
enum TestSHA256 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bitLength = UInt64(message.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in (0..<8).reversed() { data.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xFF)) }
        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                w[i] = UInt32(data[chunk + i * 4]) << 24 | UInt32(data[chunk + i * 4 + 1]) << 16
                    | UInt32(data[chunk + i * 4 + 2]) << 8 | UInt32(data[chunk + i * 4 + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.flatMap { v in (0..<4).map { UInt8((v >> (24 - UInt32($0) * 8)) & 0xFF) } }
    }
}

func hexString(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

/// A float from the golden `0x…` bit pattern.
func floatFromBits(_ text: String) -> Float {
    Float(bitPattern: UInt32(text.dropFirst(2), radix: 16)!)
}
