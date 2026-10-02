import Compression
import Foundation

/// Decoder for QQ Music's QRC word-timed lyrics (3DES with QQ's own DES variant, then zlib).
enum QRCDecoder {
    private static let sbox1: [UInt8] = [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13]
    private static let sbox2: [UInt8] = [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9]
    private static let sbox3: [UInt8] = [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12]
    private static let sbox4: [UInt8] = [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14]
    private static let sbox5: [UInt8] = [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3]
    private static let sbox6: [UInt8] = [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13]
    private static let sbox7: [UInt8] = [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12]
    private static let sbox8: [UInt8] = [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]
    private static let keyRoundShift: [UInt8] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let keyPermC: [UInt8] = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35]
    private static let keyPermD: [UInt8] = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3]
    private static let keyCompression: [UInt8] = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31]

    private static let key1 = Array("!@#)(NHLiuy*$%^&".utf8)
    private static let key2 = Array("123ZXC!@#)(*$%^&".utf8)
    private static let key3 = Array("!@#)(*$%^&abcDEF".utf8)

    private static let ipLeft: [(Int, UInt32)] = [(57,31),(49,30),(41,29),(33,28),(25,27),(17,26),(9,25),(1,24),(59,23),(51,22),(43,21),(35,20),(27,19),(19,18),(11,17),(3,16),(61,15),(53,14),(45,13),(37,12),(29,11),(21,10),(13,9),(5,8),(63,7),(55,6),(47,5),(39,4),(31,3),(23,2),(15,1),(7,0)]
    private static let ipRight: [(Int, UInt32)] = [(56,31),(48,30),(40,29),(32,28),(24,27),(16,26),(8,25),(0,24),(58,23),(50,22),(42,21),(34,20),(26,19),(18,18),(10,17),(2,16),(60,15),(52,14),(44,13),(36,12),(28,11),(20,10),(12,9),(4,8),(62,7),(54,6),(46,5),(38,4),(30,3),(22,2),(14,1),(6,0)]
    private static let pBox: [Int] = [15,6,19,20,28,11,27,16,0,14,22,25,4,17,30,9,1,7,23,13,31,26,2,8,18,12,29,5,21,10,3,24]
    private static let inverseOrder: [(Int, Int)] = [(3,7),(2,6),(1,5),(0,4),(7,3),(6,2),(5,1),(4,0)]

    private static func bitNum(_ a: [UInt8], _ b: Int, _ c: UInt32) -> UInt32 {
        ((UInt32(a[b / 32 * 4 + 3 - (b % 32) / 8]) >> UInt32(7 - (b % 8))) & 1) << c
    }
    private static func bitNumIntR(_ a: UInt32, _ b: Int, _ c: UInt32) -> UInt32 {
        ((a >> UInt32(31 - b)) & 1) << c
    }
    private static func bitNumIntL(_ a: UInt32, _ b: Int, _ c: UInt32) -> UInt32 {
        ((a << UInt32(b)) & 0x8000_0000) >> c
    }
    private static func sboxBit(_ a: UInt8) -> Int {
        Int((a & 0x20) | ((a & 0x1f) >> 1) | ((a & 0x01) << 4))
    }

    private static func f(_ state: UInt32, _ key: [UInt8]) -> UInt32 {
        let t1: UInt32 = bitNumIntL(state, 31, 0) | ((state & 0xf000_0000) >> 1) | bitNumIntL(state, 4, 5)
            | bitNumIntL(state, 3, 6) | ((state & 0x0f00_0000) >> 3) | bitNumIntL(state, 8, 11)
            | bitNumIntL(state, 7, 12) | ((state & 0x00f0_0000) >> 5) | bitNumIntL(state, 12, 17)
            | bitNumIntL(state, 11, 18) | ((state & 0x000f_0000) >> 7) | bitNumIntL(state, 16, 23)
        let t2: UInt32 = bitNumIntL(state, 15, 0) | ((state & 0x0000_f000) << 15) | bitNumIntL(state, 20, 5)
            | bitNumIntL(state, 19, 6) | ((state & 0x0000_0f00) << 13) | bitNumIntL(state, 24, 11)
            | bitNumIntL(state, 23, 12) | ((state & 0x0000_00f0) << 11) | bitNumIntL(state, 28, 17)
            | bitNumIntL(state, 27, 18) | ((state & 0x0000_000f) << 9) | bitNumIntL(state, 0, 23)
        var l: [UInt8] = [
            UInt8((t1 >> 24) & 0xff), UInt8((t1 >> 16) & 0xff), UInt8((t1 >> 8) & 0xff),
            UInt8((t2 >> 24) & 0xff), UInt8((t2 >> 16) & 0xff), UInt8((t2 >> 8) & 0xff),
        ]
        for i in 0..<6 { l[i] ^= key[i] }
        let s1 = UInt32(sbox1[sboxBit(l[0] >> 2)]) << 28
        let s2 = UInt32(sbox2[sboxBit(((l[0] & 0x03) << 4) | (l[1] >> 4))]) << 24
        let s3 = UInt32(sbox3[sboxBit(((l[1] & 0x0f) << 2) | (l[2] >> 6))]) << 20
        let s4 = UInt32(sbox4[sboxBit(l[2] & 0x3f)]) << 16
        let s5 = UInt32(sbox5[sboxBit(l[3] >> 2)]) << 12
        let s6 = UInt32(sbox6[sboxBit(((l[3] & 0x03) << 4) | (l[4] >> 4))]) << 8
        let s7 = UInt32(sbox7[sboxBit(((l[4] & 0x0f) << 2) | (l[5] >> 6))]) << 4
        let s8 = UInt32(sbox8[sboxBit(l[5] & 0x3f)])
        let substituted: UInt32 = s1 | s2 | s3 | s4 | s5 | s6 | s7 | s8
        var out: UInt32 = 0
        for (position, bit) in pBox.enumerated() {
            out |= bitNumIntL(substituted, bit, UInt32(position))
        }
        return out
    }

    private static func keySetup(_ key: [UInt8], decrypt: Bool) -> [[UInt8]] {
        var c: UInt32 = 0
        var d: UInt32 = 0
        for i in 0..<28 {
            c |= bitNum(key, Int(keyPermC[i]), UInt32(31 - i))
            d |= bitNum(key, Int(keyPermD[i]), UInt32(31 - i))
        }
        var schedule = [[UInt8]](repeating: [UInt8](repeating: 0, count: 6), count: 16)
        for i in 0..<16 {
            let shift = UInt32(keyRoundShift[i])
            c = ((c << shift) | (c >> (28 - shift))) & 0xffff_fff0
            d = ((d << shift) | (d >> (28 - shift))) & 0xffff_fff0
            let target = decrypt ? 15 - i : i
            var k = [UInt8](repeating: 0, count: 6)
            for n in 0..<24 {
                k[n / 8] |= UInt8(bitNumIntR(c, Int(keyCompression[n]), UInt32(7 - (n % 8))))
            }
            for n in 24..<48 {
                k[n / 8] |= UInt8(bitNumIntR(d, Int(keyCompression[n]) - 27, UInt32(7 - (n % 8))))
            }
            schedule[target] = k
        }
        return schedule
    }

    private static func desBlock(_ block: [UInt8], _ schedule: [[UInt8]]) -> [UInt8] {
        var s0: UInt32 = 0
        var s1: UInt32 = 0
        for (b, c) in ipLeft { s0 |= bitNum(block, b, c) }
        for (b, c) in ipRight { s1 |= bitNum(block, b, c) }
        for i in 0..<15 {
            let t = s1
            s1 = f(s1, schedule[i]) ^ s0
            s0 = t
        }
        s0 = f(s1, schedule[15]) ^ s0
        var out = [UInt8](repeating: 0, count: 8)
        for (index, base) in inverseOrder {
            var v: UInt32 = 0
            v |= bitNumIntR(s1, base, 7) | bitNumIntR(s0, base, 6)
            v |= bitNumIntR(s1, base + 8, 5) | bitNumIntR(s0, base + 8, 4)
            v |= bitNumIntR(s1, base + 16, 3) | bitNumIntR(s0, base + 16, 2)
            v |= bitNumIntR(s1, base + 24, 1) | bitNumIntR(s0, base + 24, 0)
            out[index] = UInt8(v & 0xff)
        }
        return out
    }

    private static func crypt(_ data: [UInt8], key: [UInt8], decrypt: Bool) -> [UInt8] {
        let schedule = keySetup(key, decrypt: decrypt)
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var offset = 0
        while offset + 8 <= data.count {
            out += desBlock(Array(data[offset..<offset + 8]), schedule)
            offset += 8
        }
        return out
    }

    private static func hexBytes(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        var index = 0
        while index < chars.count {
            guard let hi = nibble(chars[index]), let lo = nibble(chars[index + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            index += 2
        }
        return bytes
    }

    /// Decodes the hex payload of a `<content>` element into the QRC XML text.
    static func decode(hex: String) -> String? {
        guard var data = hexBytes(hex.trimmingCharacters(in: .whitespacesAndNewlines)), !data.isEmpty else { return nil }
        data = crypt(data, key: key1, decrypt: true)
        data = crypt(data, key: key2, decrypt: false)
        data = crypt(data, key: key3, decrypt: true)
        guard let inflated = inflateZlib(Data(data)) else { return nil }
        return String(data: inflated, encoding: .utf8)?.replacingOccurrences(of: "\u{FEFF}", with: "")
    }

    /// zlib stream (2-byte header + deflate + adler) -> raw bytes.
    private static func inflateZlib(_ data: Data) -> Data? {
        guard data.count > 6 else { return nil }
        let raw = data.dropFirst(2)
        let capacity = max(raw.count * 12, 64 * 1024)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let written: Int = raw.withUnsafeBytes { source in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(buffer, capacity, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(bytes: buffer, count: written)
    }
}