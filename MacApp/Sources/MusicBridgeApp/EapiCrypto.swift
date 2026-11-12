import Foundation

/// NetEase "eapi" request envelope, the transport the current desktop
/// and mobile clients use: the JSON payload (business fields plus a
/// `header` object describing the client) is wrapped as
/// `path-36cd479b6b5-json-36cd479b6b5-md5("nobody"+path+"use"+json+"md5forencrypt")`
/// and AES-128-ECB encrypted with the long-published eapi key, then
/// posted as the single form field `params` (uppercase hex).
///
/// Plain unsigned requests to the same endpoints get as far as the
/// phone confirmation and are then refused by NetEase risk control
/// (code 8821, "switch login method or upgrade"): the risk system
/// expects the client fingerprint the eapi header carries. AES and MD5
/// are implemented here in plain Swift so the app needs no extra
/// dependency; the AES core generates its S-box from GF(2^8)
/// arithmetic instead of a typed table, and both primitives were
/// verified against the FIPS-197 vector and OpenSSL before this file
/// shipped.
enum EapiCrypto {
    static func params(path: String, jsonText: String) -> String {
        let digest = MD5.hex("nobody\(path)use\(jsonText)md5forencrypt")
        let envelope = "\(path)-36cd479b6b5-\(jsonText)-36cd479b6b5-\(digest)"
        let encrypted = AES128.encryptECBPKCS7([UInt8](envelope.utf8),
                                               key: [UInt8]("e82ckenh8dichen8".utf8))
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }
}

// MARK: - AES-128 (ECB, PKCS#7; decrypt added for stage 5c .ncm)

enum AES128 {
    private static let sBox: [UInt8] = buildSBox()
    private static let rcon: [UInt8] = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]

    private static func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a
        var b = b
        var p: UInt8 = 0
        for _ in 0..<8 {
            if b & 1 != 0 { p ^= a }
            let hi = a & 0x80
            a <<= 1
            if hi != 0 { a ^= 0x1B }
            b >>= 1
        }
        return p
    }

    private static func buildSBox() -> [UInt8] {
        func gfInv(_ a: UInt8) -> UInt8 {
            if a == 0 { return 0 }
            for i in 1...255 where gfMul(a, UInt8(i)) == 1 { return UInt8(i) }
            return 0
        }
        return (0...255).map { i in
            let inv = gfInv(UInt8(i))
            var s = inv
            for r in 1...4 {
                s ^= (inv << r) | (inv >> (8 - r))
            }
            return s ^ 0x63
        }
    }

    private static func expandKey(_ key: [UInt8]) -> [UInt8] {
        var w = key
        for i in 4..<44 {
            var t = [UInt8](w[(4 * (i - 1))..<(4 * i)])
            if i % 4 == 0 {
                t = [sBox[Int(t[1])] ^ rcon[i / 4 - 1], sBox[Int(t[2])], sBox[Int(t[3])], sBox[Int(t[0])]]
            }
            for j in 0..<4 {
                w.append(w[4 * (i - 4) + j] ^ t[j])
            }
        }
        return w
    }

    /// State is kept in the FIPS-197 layout: byte 4c+r is row r,
    /// column c, matching the order bytes arrive and leave.
    private static func encryptBlock(_ block: [UInt8], expanded: [UInt8]) -> [UInt8] {
        var s = block
        func addRoundKey(_ round: Int) {
            for i in 0..<16 { s[i] ^= expanded[16 * round + i] }
        }
        func subBytes() {
            for i in 0..<16 { s[i] = sBox[Int(s[i])] }
        }
        func shiftRows() {
            for r in 1..<4 {
                let row = (0..<4).map { s[4 * $0 + r] }
                for c in 0..<4 { s[4 * c + r] = row[(c + r) % 4] }
            }
        }
        func mixColumns() {
            for c in 0..<4 {
                let a = (0..<4).map { s[4 * c + $0] }
                s[4 * c + 0] = gfMul(a[0], 2) ^ gfMul(a[1], 3) ^ a[2] ^ a[3]
                s[4 * c + 1] = a[0] ^ gfMul(a[1], 2) ^ gfMul(a[2], 3) ^ a[3]
                s[4 * c + 2] = a[0] ^ a[1] ^ gfMul(a[2], 2) ^ gfMul(a[3], 3)
                s[4 * c + 3] = gfMul(a[0], 3) ^ a[1] ^ a[2] ^ gfMul(a[3], 2)
            }
        }
        addRoundKey(0)
        for round in 1..<10 {
            subBytes()
            shiftRows()
            mixColumns()
            addRoundKey(round)
        }
        subBytes()
        shiftRows()
        addRoundKey(10)
        return s
    }

    static func encryptECBPKCS7(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        let expanded = expandKey(key)
        let pad = 16 - (data.count % 16)
        let padded = data + [UInt8](repeating: UInt8(pad), count: pad)
        var out: [UInt8] = []
        out.reserveCapacity(padded.count)
        for offset in stride(from: 0, to: padded.count, by: 16) {
            out += encryptBlock([UInt8](padded[offset..<(offset + 16)]), expanded: expanded)
        }
        return out
    }

    // MARK: Decryption (stage 5c: the .ncm decoder unwraps its key and
    // metadata with AES-128-ECB; the key expansion above is shared.)

    private static let invSBox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sBox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()

    private static func decryptBlock(_ block: [UInt8], expanded: [UInt8]) -> [UInt8] {
        var s = block
        func addRoundKey(_ round: Int) {
            for i in 0..<16 { s[i] ^= expanded[16 * round + i] }
        }
        func invSubBytes() {
            for i in 0..<16 { s[i] = invSBox[Int(s[i])] }
        }
        func invShiftRows() {
            for r in 1..<4 {
                let row = (0..<4).map { s[4 * $0 + r] }
                for c in 0..<4 { s[4 * c + r] = row[(c - r + 4) % 4] }
            }
        }
        func invMixColumns() {
            for c in 0..<4 {
                let a = (0..<4).map { s[4 * c + $0] }
                s[4 * c + 0] = gfMul(a[0], 14) ^ gfMul(a[1], 11) ^ gfMul(a[2], 13) ^ gfMul(a[3], 9)
                s[4 * c + 1] = gfMul(a[0], 9) ^ gfMul(a[1], 14) ^ gfMul(a[2], 11) ^ gfMul(a[3], 13)
                s[4 * c + 2] = gfMul(a[0], 13) ^ gfMul(a[1], 9) ^ gfMul(a[2], 14) ^ gfMul(a[3], 11)
                s[4 * c + 3] = gfMul(a[0], 11) ^ gfMul(a[1], 13) ^ gfMul(a[2], 9) ^ gfMul(a[3], 14)
            }
        }
        addRoundKey(10)
        for round in stride(from: 9, through: 1, by: -1) {
            invShiftRows()
            invSubBytes()
            addRoundKey(round)
            invMixColumns()
        }
        invShiftRows()
        invSubBytes()
        addRoundKey(0)
        return s
    }

    /// ECB decrypt with PKCS#7 unpadding; nil when the input is not a
    /// whole number of blocks or the padding does not check out.
    static func decryptECBPKCS7(_ data: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty, data.count % 16 == 0 else { return nil }
        let expanded = expandKey(key)
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for offset in stride(from: 0, to: data.count, by: 16) {
            out += decryptBlock([UInt8](data[offset..<(offset + 16)]), expanded: expanded)
        }
        guard let pad = out.last, pad >= 1, pad <= 16, out.count >= Int(pad),
              out.suffix(Int(pad)).allSatisfy({ $0 == pad }) else { return nil }
        return [UInt8](out.dropLast(Int(pad)))
    }
}

// MARK: - MD5

enum MD5 {
    static func hex(_ text: String) -> String {
        digest([UInt8](text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    private static let k: [UInt32] = [
        0xD76AA478, 0xE8C7B756, 0x242070DB, 0xC1BDCEEE, 0xF57C0FAF, 0x4787C62A, 0xA8304613, 0xFD469501,
        0x698098D8, 0x8B44F7AF, 0xFFFF5BB1, 0x895CD7BE, 0x6B901122, 0xFD987193, 0xA679438E, 0x49B40821,
        0xF61E2562, 0xC040B340, 0x265E5A51, 0xE9B6C7AA, 0xD62F105D, 0x02441453, 0xD8A1E681, 0xE7D3FBC8,
        0x21E1CDE6, 0xC33707D6, 0xF4D50D87, 0x455A14ED, 0xA9E3E905, 0xFCEFA3F8, 0x676F02D9, 0x8D2A4C8A,
        0xFFFA3942, 0x8771F681, 0x6D9D6122, 0xFDE5380C, 0xA4BEEA44, 0x4BDECFA9, 0xF6BB4B60, 0xBEBFBC70,
        0x289B7EC6, 0xEAA127FA, 0xD4EF3085, 0x04881D05, 0xD9D4D039, 0xE6DB99E5, 0x1FA27CF8, 0xC4AC5665,
        0xF4292244, 0x432AFF97, 0xAB9423A7, 0xFC93A039, 0x655B59C3, 0x8F0CCC92, 0xFFEFF47D, 0x85845DD1,
        0x6FA87E4F, 0xFE2CE6E0, 0xA3014314, 0x4E0811A1, 0xF7537E82, 0xBD3AF235, 0x2AD7D2BB, 0xEB86D391,
    ]

    static func digest(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(input.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in 0..<8 { message.append(UInt8((bitLength >> (8 * i)) & 0xFF)) }

        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476]
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 16)
            for j in 0..<16 {
                let base = chunkStart + 4 * j
                words[j] = UInt32(message[base])
                    | (UInt32(message[base + 1]) << 8)
                    | (UInt32(message[base + 2]) << 16)
                    | (UInt32(message[base + 3]) << 24)
            }
            var (a, b, c, d) = (h[0], h[1], h[2], h[3])
            for i in 0..<64 {
                let f: UInt32
                let g: Int
                switch i / 16 {
                case 0:
                    f = (b & c) | (~b & d)
                    g = i
                case 1:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 2:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                let tmp = d
                d = c
                c = b
                let sum = a &+ f &+ k[i] &+ words[g]
                b = b &+ ((sum << shifts[i]) | (sum >> (32 - shifts[i])))
                a = tmp
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
        }
        var out: [UInt8] = []
        for value in h {
            for i in 0..<4 { out.append(UInt8((value >> (8 * i)) & 0xFF)) }
        }
        return out
    }
}
