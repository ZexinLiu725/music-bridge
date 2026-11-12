import Foundation

/// Pure-Swift .ncm decoder (stage 5c), implementing the long-documented
/// ncmdump container format. The official client encrypts an already
/// authorized download at rest; this unwraps it locally, offline, with
/// no account involved, so the song can join the normal import flow.
///
/// Layout: magic "CTENFDAM" + 2 gap bytes; a key block (XOR 0x64,
/// AES-128-ECB with the core key, 17-byte "neteasecloudmusic" prefix
/// before the real audio key); a metadata block (XOR 0x63, a 22-byte
/// "163 key(Don't modify):" prefix, base64, AES-128-ECB with the meta
/// key, a 6-byte "music:" prefix before the JSON); CRC + gap; an
/// optional cover image; then the audio bytes XORed with an RC4-style
/// key-box stream.
enum NcmDecoder {
    struct Song {
        var title: String = ""
        var artist: String = ""
        var album: String = ""
        /// "mp3" or "flac", from the audio magic bytes (metadata as fallback).
        var format: String
        var audio: Data
        var cover: Data? = nil
        var coverMIME: String { cover?.prefix(3).elementsEqual([0x89, 0x50, 0x4E]) == true ? "image/png" : "image/jpeg" }
    }

    enum DecodeError: LocalizedError {
        case notNCM
        case truncated
        case badKeyBlock
        case unknownAudio

        var errorDescription: String? {
            switch self {
            case .notNCM: return "不是 .ncm 文件（文件头不符）"
            case .truncated: return ".ncm 文件不完整或已损坏"
            case .badKeyBlock: return ".ncm 密钥段异常，无法解码"
            case .unknownAudio: return "解码后无法识别音频格式"
            }
        }
    }

    /// AES keys as published in every open ncmdump implementation.
    private static let coreKey: [UInt8] = [0x68, 0x7A, 0x48, 0x52, 0x41, 0x6D, 0x73, 0x6F,
                                           0x35, 0x6B, 0x49, 0x6E, 0x62, 0x61, 0x78, 0x57]
    private static let metaKey: [UInt8] = [0x23, 0x31, 0x34, 0x6C, 0x6A, 0x6B, 0x5F, 0x21,
                                           0x5C, 0x5D, 0x26, 0x30, 0x55, 0x3C, 0x27, 0x28]

    static func decode(_ bytes: [UInt8]) throws -> Song {
        var cursor = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, cursor + count <= bytes.count else { throw DecodeError.truncated }
            defer { cursor += count }
            return bytes[cursor..<(cursor + count)]
        }
        func takeU32() throws -> Int {
            let b = try take(4)
            return Int(b[b.startIndex]) | Int(b[b.startIndex + 1]) << 8 | Int(b[b.startIndex + 2]) << 16 | Int(b[b.startIndex + 3]) << 24
        }

        // Magic + 2 unused bytes.
        guard bytes.count >= 10, Array(bytes[0..<8]) == [UInt8]("CTENFDAM".utf8) else { throw DecodeError.notNCM }
        cursor = 10

        // Key block: XOR 0x64, AES-ECB (core key), skip the 17-byte prefix.
        let keyLength = try takeU32()
        let keyBlock = try take(keyLength).map { $0 ^ 0x64 }
        guard let keyPlain = AES128.decryptECBPKCS7(keyBlock, key: coreKey), keyPlain.count > 17 else {
            throw DecodeError.badKeyBlock
        }
        let audioKey = [UInt8](keyPlain.dropFirst(17))
        guard !audioKey.isEmpty else { throw DecodeError.badKeyBlock }
        let box = keyBox(audioKey)

        // Metadata block. Failure here must not sink the decode: the
        // audio key is already recovered, so tags fall back to empty.
        var metaTitle = "", metaArtist = "", metaAlbum = "", metaFormat = ""
        let metaLength = try takeU32()
        let metaBlock = try take(metaLength)
        if metaLength > 22 {
            let unmasked = metaBlock.map { $0 ^ 0x63 }
            let base64Text = String(bytes: [UInt8](unmasked.dropFirst(22)), encoding: .utf8) ?? ""
            if let cipher = Data(base64Encoded: base64Text),
               let plain = AES128.decryptECBPKCS7([UInt8](cipher), key: metaKey), plain.count > 6,
               let json = try? JSONSerialization.jsonObject(with: Data(plain.dropFirst(6))),
               let dict = json as? [String: Any] {
                metaTitle = dict["musicName"] as? String ?? ""
                metaAlbum = dict["album"] as? String ?? ""
                metaFormat = (dict["format"] as? String ?? "").lowercased()
                if let artists = dict["artist"] as? [[Any]] {
                    metaArtist = artists.compactMap { $0.first as? String }.joined(separator: "/")
                } else if let artist = dict["artist"] as? String {
                    metaArtist = artist
                }
            }
        }

        // CRC (4) + gap (5), then the optional embedded cover.
        _ = try take(4 + 5)
        let imageSize = try takeU32()
        var cover: Data? = nil
        if imageSize > 0 {
            cover = Data(try take(imageSize))
        }

        // Audio: XOR with the key-box stream; the position counter runs
        // across the whole audio segment.
        var audio = [UInt8](bytes[cursor...])
        for i in audio.indices {
            let j = (i + 1) & 0xFF
            let a = Int(box[j])
            let b = Int(box[(a + j) & 0xFF])
            audio[i] ^= box[(a + b) & 0xFF]
        }

        // Format from magic bytes; the metadata value is the fallback.
        var format = ""
        if audio.count >= 4, Array(audio[0..<4]) == [UInt8]("fLaC".utf8) {
            format = "flac"
        } else if audio.count >= 3, Array(audio[0..<3]) == [UInt8]("ID3".utf8) {
            format = "mp3"
        } else if audio.count >= 2, audio[0] == 0xFF, [0xFB, 0xF3, 0xF2, 0xFA].contains(audio[1]) {
            format = "mp3"
        } else if metaFormat == "flac" || metaFormat == "mp3" {
            format = metaFormat
        }
        guard !format.isEmpty else { throw DecodeError.unknownAudio }

        return Song(title: metaTitle, artist: metaArtist, album: metaAlbum,
                    format: format, audio: Data(audio), cover: cover)
    }

    /// RC4 key scheduling over the recovered audio key.
    private static func keyBox(_ key: [UInt8]) -> [UInt8] {
        var box = (0...255).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(box[i]) + Int(key[i % key.count])) & 0xFF
            box.swapAt(i, j)
        }
        return box
    }
}
