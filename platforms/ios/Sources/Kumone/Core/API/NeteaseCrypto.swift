import Foundation
import CommonCrypto
import CryptoKit

/// NetEase Cloud Music request encryption (weapi / eapi).
///
/// weapi: two rounds of AES-128-CBC over the JSON payload — first with a preset
/// key, then with a client-chosen secret key. The secret key is normally
/// RSA-encrypted per request; since the key is chosen by us, we ship a fixed
/// key with its RSA ciphertext precomputed, avoiding a BigInt implementation.
///
/// eapi: AES-128-ECB over "url + payload + md5 digest" with a fixed key, hex output.
enum NeteaseCrypto {
    private static let weapiPresetKey = "0CoJUm6Qyw8W8jud"
    private static let weapiIV = "0102030405060708"
    private static let weapiSecretKey = "kumone2026abcDEF"
    private static let weapiEncSecKey =
        "38cef2efdbcc1cfd6a44d81620dae5d23091f50ef27e01a1b1bb7e998e0fde2d" +
        "7ab6002a9e79a3c195f661cbde80e21e6245997b11b54d28407115822f95d447" +
        "7cc06b5a77de46fab6568410abf1229abef81b4c8588f386149010d190bb0b04" +
        "f064be330bd877a4d4b99514febbdb4335b10744b13d9f7ee24d314d6e62cdc9"
    private static let eapiKey = "e82ckenh8dichen8"

    /// Encrypts a JSON payload for a `/weapi/...` endpoint.
    /// Returns the form body fields.
    static func weapi(payload: Data) -> [String: String] {
        let first = aes128(payload, key: weapiPresetKey, cbcIV: weapiIV).base64EncodedData()
        let second = aes128(first, key: weapiSecretKey, cbcIV: weapiIV).base64EncodedString()
        return ["params": second, "encSecKey": weapiEncSecKey]
    }

    /// Encrypts a JSON payload for an `/eapi/...` endpoint.
    /// - Parameter apiPath: the internal API path, e.g. "/api/song/enhance/player/url/v1"
    static func eapi(apiPath: String, payload: Data) -> [String: String] {
        let text = String(decoding: payload, as: UTF8.self)
        let message = "nobody\(apiPath)use\(text)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(message.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let data = "\(apiPath)-36cd479b6b5-\(text)-36cd479b6b5-\(digest)"
        let encrypted = aes128(Data(data.utf8), key: eapiKey, cbcIV: nil)
        return ["params": encrypted.map { String(format: "%02X", $0) }.joined()]
    }

    /// AES-128 encryption with PKCS7 padding. CBC when `cbcIV` is given, ECB otherwise.
    private static func aes128(_ data: Data, key: String, cbcIV: String?) -> Data {
        let keyData = Data(key.utf8)
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let options: CCOptions = cbcIV == nil
            ? CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode)
            : CCOptions(kCCOptionPKCS7Padding)
        let ivData = cbcIV.map { Data($0.utf8) }

        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    if let ivData {
                        return ivData.withUnsafeBytes { ivPtr in
                            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                    options, keyPtr.baseAddress, keyData.count, ivPtr.baseAddress,
                                    dataPtr.baseAddress, data.count,
                                    outPtr.baseAddress, outPtr.count, &written)
                        }
                    } else {
                        return CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                       options, keyPtr.baseAddress, keyData.count, nil,
                                       dataPtr.baseAddress, data.count,
                                       outPtr.baseAddress, outPtr.count, &written)
                    }
                }
            }
        }
        precondition(status == kCCSuccess, "AES encryption failed: \(status)")
        return out.prefix(written)
    }
}
