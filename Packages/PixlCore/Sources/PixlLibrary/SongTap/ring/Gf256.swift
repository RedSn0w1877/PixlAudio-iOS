// GF(2^8) with the primitive polynomial x^8 + x^4 + x^3 + x^2 + 1 (0x11D) and the generator alpha = 2, the field of QR codes
// and CD audio. Integers only; the tables are built from the polynomial (a transliteration of the Android `Gf256.kt`).

public enum Gf256 {
    public static let primitive = 0x11D

    /// exp[i] = alpha^i for i in 0..<512 (doubled, so a product of two logs needs no modulo), and log[x].
    private static let tables: (exp: [Int], log: [Int]) = {
        var exp = [Int](repeating: 0, count: 512)
        var log = [Int](repeating: 0, count: 256)
        var x = 1
        for i in 0..<255 {
            exp[i] = x
            log[x] = i
            x <<= 1
            if x & 0x100 != 0 { x ^= primitive }
        }
        for i in 255..<512 { exp[i] = exp[i - 255] }
        return (exp, log)
    }()

    public static func add(_ a: Int, _ b: Int) -> Int { a ^ b }

    public static func mul(_ a: Int, _ b: Int) -> Int {
        if a == 0 || b == 0 { return 0 }
        return tables.exp[tables.log[a] + tables.log[b]]
    }

    public static func div(_ a: Int, _ b: Int) -> Int {
        precondition(b != 0, "division by zero in GF(256)")
        if a == 0 { return 0 }
        return tables.exp[tables.log[a] + 255 - tables.log[b]]
    }

    public static func inv(_ a: Int) -> Int {
        precondition(a != 0, "zero has no inverse")
        return tables.exp[255 - tables.log[a]]
    }

    /// alpha^n for any integer n (negative allowed).
    public static func alphaPow(_ n: Int) -> Int {
        var k = n % 255
        if k < 0 { k += 255 }
        return tables.exp[k]
    }

    public static func logOf(_ a: Int) -> Int {
        precondition(a != 0, "log of zero")
        return tables.log[a]
    }
}
