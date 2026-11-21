// Reed-Solomon RS(25, 11) over GF(256): 11 data bytes, 14 parity bytes, minimum distance 15. It corrects `e` unknown byte
// errors and `s` known-position erasures whenever 2e + s <= 14: 7 errors, or 14 erasures, or any mix. Systematic: a
// codeword is the data followed by the parity. The generator has the roots alpha^0 ... alpha^13. A transliteration of the
// Android `ReedSolomon.kt`: integers only, no allocation beyond the small work arrays, the same answer for every input
// (even beyond the code's capacity, where the golden file lists what the Kotlin decoder returns).
//
// The scanner uses the erasure form: a slot it could not see (a smudge, a glare patch) is flagged, and a flagged byte
// costs one parity byte instead of two.

/// What `ReedSolomon.decode` found. `codeword` is the corrected word (25 bytes) when `ok`.
public struct RsDecode: Sendable, Equatable {
    public let ok: Bool
    public let codeword: [UInt8]?
    /// Unknown-position bytes that were repaired (erasures are not counted).
    public let corrected: Int
    public let erasuresUsed: Int

    public init(ok: Bool, codeword: [UInt8]?, corrected: Int, erasuresUsed: Int) {
        self.ok = ok
        self.codeword = codeword
        self.corrected = corrected
        self.erasuresUsed = erasuresUsed
    }

    public static let failed = RsDecode(ok: false, codeword: nil, corrected: 0, erasuresUsed: 0)
}

public enum ReedSolomon {
    public static let n = 25
    public static let k = 11
    public static let nsym = n - k

    /// Generator polynomial, highest degree first, monic, degree 14 (15 coefficients).
    private static let generator: [Int] = {
        var g = [1]
        for i in 0..<nsym {
            let root = Gf256.alphaPow(i)
            var next = [Int](repeating: 0, count: g.count + 1)
            for j in g.indices {
                next[j] ^= g[j]
                next[j + 1] ^= Gf256.mul(g[j], root)
            }
            g = next
        }
        return g
    }()

    /// The 14 parity bytes of `data` (11 bytes), as a new 25-byte codeword.
    public static func encode(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count == k, "RS(25,11) takes 11 data bytes, got \(data.count)")
        var rem = [Int](repeating: 0, count: nsym)
        for i in 0..<k {
            let feedback = Int(data[i]) ^ rem[0]
            for j in 0..<(nsym - 1) { rem[j] = rem[j + 1] ^ Gf256.mul(feedback, generator[j + 1]) }
            rem[nsym - 1] = Gf256.mul(feedback, generator[nsym])
        }
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<k { out[i] = data[i] }
        for i in 0..<nsym { out[k + i] = UInt8(truncatingIfNeeded: rem[i]) }
        return out
    }

    private static func syndromes(_ word: [Int], _ out: inout [Int]) -> Bool {
        var clean = true
        for i in 0..<nsym {
            let x = Gf256.alphaPow(i)
            var acc = 0
            for j in 0..<n { acc = Gf256.mul(acc, x) ^ word[j] }
            out[i] = acc
            if acc != 0 { clean = false }
        }
        return clean
    }

    /// True when `word` (25 bytes) is a codeword.
    public static func isCodeword(_ word: [UInt8]) -> Bool {
        if word.count != n { return false }
        let w = word.map { Int($0) }
        var s = [Int](repeating: 0, count: nsym)
        return syndromes(w, &s)
    }

    /// Corrects `received` (25 bytes). `erasures` lists byte positions (0..24, no duplicates) the caller does not trust; the
    /// values there are ignored. Returns `RsDecode.failed` when the word is further than the code can repair; the result is
    /// verified (its syndromes are zero) before it is returned.
    public static func decode(_ received: [UInt8], erasures: [Int] = []) -> RsDecode {
        if received.count != n { return .failed }
        let s = erasures.count
        if s > nsym { return .failed }
        var seen = [Bool](repeating: false, count: n)
        for p in erasures {
            if p < 0 || p >= n || seen[p] { return .failed }
            seen[p] = true
        }
        var word = [Int](repeating: 0, count: n)
        for i in 0..<n { word[i] = seen[i] ? 0 : Int(received[i]) }
        var synd = [Int](repeating: 0, count: nsym)
        if syndromes(word, &synd) {
            var out = received
            for p in erasures { out[p] = UInt8(truncatingIfNeeded: word[p]) }
            return RsDecode(ok: true, codeword: out, corrected: 0, erasuresUsed: s)
        }

        // Erasure locator, lowest degree first: product of (1 + alpha^p x), p = n - 1 - position.
        var gamma = [1]
        for pos in erasures {
            let x = Gf256.alphaPow(n - 1 - pos)
            var next = [Int](repeating: 0, count: gamma.count + 1)
            for i in gamma.indices {
                next[i] ^= gamma[i]
                next[i + 1] ^= Gf256.mul(gamma[i], x)
            }
            gamma = next
        }

        // Modified syndromes T(x) = S(x) * Gamma(x) mod x^14; the error-only recurrence lives in T[s..13].
        var t = [Int](repeating: 0, count: nsym)
        for i in 0..<nsym {
            var acc = 0
            for j in gamma.indices where i - j >= 0 { acc ^= Gf256.mul(gamma[j], synd[i - j]) }
            t[i] = acc
        }

        // Berlekamp-Massey on T[s..13].
        let m = nsym - s
        var c = [1]
        var b = [1]
        var l = 0
        var shift = 1
        var bd = 1
        for step in 0..<m {
            var d = t[s + step]
            if l >= 1 {
                for i in 1...l where i < c.count { d ^= Gf256.mul(c[i], t[s + step - i]) }
            }
            if d == 0 {
                shift += 1
            } else {
                let coef = Gf256.div(d, bd)
                let size = max(c.count, b.count + shift)
                var nc = [Int](repeating: 0, count: size)
                for i in c.indices { nc[i] = c[i] }
                for i in b.indices { nc[i + shift] ^= Gf256.mul(coef, b[i]) }
                if 2 * l <= step {
                    b = c
                    bd = d
                    l = step + 1 - l
                    shift = 1
                } else {
                    shift += 1
                }
                c = nc
            }
        }
        if 2 * l > m { return .failed }

        // Total locator Psi = Lambda * Gamma (lowest degree first), trimmed.
        var psiRaw = [Int](repeating: 0, count: c.count + gamma.count - 1)
        for i in c.indices { for j in gamma.indices { psiRaw[i + j] ^= Gf256.mul(c[i], gamma[j]) } }
        var degree = psiRaw.count - 1
        while degree > 0 && psiRaw[degree] == 0 { degree -= 1 }
        if degree == 0 { return .failed }
        let psi = Array(psiRaw[0...degree])

        // Chien search: position j has locator X = alpha^(n-1-j); it is a root when Psi(X^-1) = 0.
        var errorPos = [Int](repeating: 0, count: degree)
        var found = 0
        for j in 0..<n {
            let xInv = Gf256.alphaPow(-(n - 1 - j))
            var acc = 0
            var i = degree
            while i >= 0 { acc = Gf256.mul(acc, xInv) ^ psi[i]; i -= 1 }
            if acc == 0 {
                if found == degree { return .failed }
                errorPos[found] = j
                found += 1
            }
        }
        if found != degree { return .failed }
        for p in erasures {
            var has = false
            for k in 0..<found where errorPos[k] == p { has = true }
            if !has { return .failed }
        }

        // Evaluator Omega = S * Psi mod x^14; Forney (first root alpha^0): e = X * Omega(X^-1) / Psi'(X^-1).
        var omega = [Int](repeating: 0, count: nsym)
        for i in 0..<nsym {
            var acc = 0
            for j in psi.indices where i - j >= 0 { acc ^= Gf256.mul(psi[j], synd[i - j]) }
            omega[i] = acc
        }
        var fixed = word
        for idx in 0..<found {
            let pos = errorPos[idx]
            let x = Gf256.alphaPow(n - 1 - pos)
            let xInv = Gf256.inv(x)
            var num = 0
            var i = nsym - 1
            while i >= 0 { num = Gf256.mul(num, xInv) ^ omega[i]; i -= 1 }
            var den = 0
            var q = 1
            while q <= degree {
                if q < psi.count { den ^= Gf256.mul(psi[q], powOf(xInv, q - 1)) }
                q += 2
            }
            if den == 0 { return .failed }
            let magnitude = Gf256.mul(x, Gf256.div(num, den))
            fixed[pos] ^= magnitude
        }
        var check = [Int](repeating: 0, count: nsym)
        if !syndromes(fixed, &check) { return .failed }
        var out = [UInt8](repeating: 0, count: n)
        for i in 0..<n { out[i] = UInt8(truncatingIfNeeded: fixed[i]) }
        var changed = 0
        for idx in 0..<found {
            let pos = errorPos[idx]
            if !seen[pos] && out[pos] != received[pos] { changed += 1 }
        }
        return RsDecode(ok: true, codeword: out, corrected: changed, erasuresUsed: s)
    }

    private static func powOf(_ x: Int, _ e: Int) -> Int {
        var r = 1
        for _ in 0..<e { r = Gf256.mul(r, x) }
        return r
    }
}
