import Foundation

enum NetEaseCrypto {
    private static let fixedKey = Data("0CoJUm6Qyw8W8jud".utf8)
    private static let fixedIV = Data("0102030405060708".utf8)
    private static let eapiKey = Data("e82ckenh8dichen8".utf8)
    private static let rsaModulusHex = "00e0b509f6259df8642dbc35662901477df22677ec152b5ff68ace615bb7b725152b3ab17a876aea8a5aa76d2e417629ec4ee341f56135fccf695280104e0312ecbda92557c93870114af6c9d05c4f7f0c3685b7a46bee255932575cce10b424d813cfe4875d3e82047b97ddef52741d546b8e289dc6935b3ece0462db0a22b8e7"

    // MARK: - AES-128-CBC (weapi 第一层)

    private static func aesCBCEncrypt(_ input: Data, key: Data) -> Data? {
        var outBytes = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLen: size_t = 0
        let status = key.withUnsafeBytes { keyBytes in
            fixedIV.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { dataBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        ivBytes.baseAddress,
                        dataBytes.baseAddress, input.count,
                        &outBytes, outBytes.count,
                        &outLen
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(outBytes.prefix(outLen))
    }

    // MARK: - AES-128-ECB (eapi)

    private static func aesECBEncrypt(_ input: Data, key: Data) -> Data? {
        var outBytes = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outLen: size_t = 0
        let status = key.withUnsafeBytes { keyBytes in
            input.withUnsafeBytes { dataBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    keyBytes.baseAddress, key.count,
                    nil,
                    dataBytes.baseAddress, input.count,
                    &outBytes, outBytes.count,
                    &outLen
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(outBytes.prefix(outLen))
    }

    // MARK: - weapi（密钥反转 + RAW RSA 无填充）

    static func weapi(_ payload: [String: Any]) -> [String: String] {
        let text = jsonString(payload)
        guard let first = aesCBCEncrypt(Data(text.utf8), key: fixedKey) else { return [:] }
        let secretKey = random16()
        guard let second = aesCBCEncrypt(Data(first.base64EncodedString().utf8), key: Data(secretKey.utf8)) else { return [:] }
        let reversed = String(secretKey.reversed())
        guard let encSecKey = rawRSAEncrypt(Data(reversed.utf8)) else { return [:] }
        return [
            "params": second.base64EncodedString(),
            "encSecKey": hexString(encSecKey),
        ]
    }

    // MARK: - eapi（params 单字段）

    static func eapi(_ payload: [String: Any], path: String) -> [String: String] {
        let text = jsonString(payload)
        let message = "nobody\(path)use\(text)md5forencrypt"
        let digest = Data(message.utf8).md5Hex()
        let data = "\(path)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        guard let params = aesECBEncrypt(Data(data.utf8), key: eapiKey) else { return [:] }
        return ["params": hexString(params)]
    }

    // MARK: - RAW RSA（m^e mod n，无填充）

    static func rawRSAEncrypt(_ input: Data) -> Data? {
        let modulus = BigUInt(hexString: rsaModulusHex)
        let message = BigUInt(data: input)
        let result = message.pow(65_537, mod: modulus)
        return result.data(count: 128)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func random16() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<16).compactMap { _ in chars.randomElement() ?? "a" })
    }

    private static func jsonString(_ payload: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - 简易大整数（正数、小端 UInt32 limbs）

struct BigUInt {
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(integer: UInt32) {
        self.limbs = integer == 0 ? [] : [integer]
    }

    init(data: Data) {
        let bytes = [UInt8](data)
        var result: [UInt32] = []
        var i = bytes.count
        while i > 0 {
            let start = max(0, i - 4)
            var value: UInt32 = 0
            for j in start..<i {
                value = (value << 8) | UInt32(bytes[j])
            }
            result.append(value)
            i = start
        }
        self.init(limbs: result)
    }

    init(hexString: String) {
        var s = hexString
        if s.hasPrefix("0x") { s.removeFirst(2) }
        if s.count % 2 != 0 { s = "0" + s }
        var bytes: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            bytes.append(UInt8(s[idx..<next], radix: 16) ?? 0)
            idx = next
        }
        self.init(data: Data(bytes))
    }

    var isZero: Bool { limbs.allSatisfy { $0 == 0 } }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 {
            limbs.removeLast()
        }
    }

    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private func bit(at index: Int) -> Bool {
        let limbIndex = index / 32
        guard limbIndex < limbs.count else { return false }
        return limbs[limbIndex] & (1 << UInt32(index % 32)) != 0
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    static func == (lhs: BigUInt, rhs: BigUInt) -> Bool {
        lhs.limbs == rhs.limbs
    }

    static func >= (lhs: BigUInt, rhs: BigUInt) -> Bool {
        !(lhs < rhs)
    }

    func doubled() -> BigUInt {
        var result: [UInt32] = []
        var carry: UInt32 = 0
        for limb in limbs {
            let v = (limb << 1) | carry
            result.append(v)
            carry = limb >> 31
        }
        if carry != 0 { result.append(carry) }
        return BigUInt(limbs: result)
    }

    func incremented() -> BigUInt {
        var result = limbs
        var i = 0
        while i < result.count {
            let v = result[i] &+ 1
            result[i] = v
            if v != 0 { break }
            i += 1
        }
        if i == result.count { result.append(1) }
        return BigUInt(limbs: result)
    }

    func subtracting(_ other: BigUInt) -> BigUInt {
        var result: [UInt32] = []
        var borrow: UInt32 = 0
        let count = max(limbs.count, other.limbs.count)
        for i in 0..<count {
            let a = i < limbs.count ? limbs[i] : 0
            let b = i < other.limbs.count ? other.limbs[i] : 0
            let (diff, b1) = a.subtractingReportingOverflow(b)
            let (diff2, b2) = diff.subtractingReportingOverflow(borrow)
            result.append(diff2)
            borrow = (b1 || b2) ? 1 : 0
        }
        return BigUInt(limbs: result)
    }

    func multiplied(by other: BigUInt) -> BigUInt {
        var result = [UInt64](repeating: 0, count: limbs.count + other.limbs.count)
        for i in 0..<limbs.count {
            var carry: UInt64 = 0
            for j in 0..<other.limbs.count {
                let cur = result[i + j] + UInt64(limbs[i]) * UInt64(other.limbs[j]) + carry
                result[i + j] = cur & 0xFFFF_FFFF
                carry = cur >> 32
            }
            var k = i + other.limbs.count
            var c = carry
            while c != 0 && k < result.count {
                let s = result[k] + c
                result[k] = s & 0xFFFF_FFFF
                c = s >> 32
                k += 1
            }
        }
        return BigUInt(limbs: result.map { UInt32($0 & 0xFFFF_FFFF) })
    }

    func mod(_ n: BigUInt) -> BigUInt {
        if n.isZero { return BigUInt(integer: 0) }
        if self < n { return self }
        var r = BigUInt(integer: 0)
        let bits = bitWidth
        guard bits > 0 else { return r }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            r = r.doubled()
            if bit(at: i) {
                r = r.incremented()
            }
            if r >= n {
                r = r.subtracting(n)
            }
        }
        return r
    }

    func pow(_ exponent: UInt32, mod n: BigUInt) -> BigUInt {
        var result = BigUInt(integer: 1)
        var base = self.mod(n)
        var exp = exponent
        while exp > 0 {
            if exp & 1 == 1 {
                result = result.multiplied(by: base).mod(n)
            }
            base = base.multiplied(by: base).mod(n)
            exp >>= 1
        }
        return result
    }

    func data(count: Int) -> Data {
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            bytes.append(UInt8((limb >> 24) & 0xFF))
            bytes.append(UInt8((limb >> 16) & 0xFF))
            bytes.append(UInt8((limb >> 8) & 0xFF))
            bytes.append(UInt8(limb & 0xFF))
        }
        while bytes.count > count {
            bytes.removeFirst()
        }
        while bytes.count < count {
            bytes.insert(0, at: 0)
        }
        return Data(bytes)
    }
}

extension Data {
    init(hexString: String) {
        // 修复：奇数长度 hex 时 index+2 会越界崩溃；先补前导 0 保证成对解析
        var hex = hexString
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        if !hex.count.isMultiple(of: 2) { hex = "0" + hex }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            if let byte = UInt8(hex[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        self.init(bytes)
    }

    func md5Hex() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}