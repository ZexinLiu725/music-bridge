import Foundation

/// Minimal tag writers for decoded .ncm songs (stage 5c), so a decoded
/// file carries the same title / artist / album / cover the download
/// paths produce. MP3 gets an ID3v2.3 tag; FLAC gets Vorbis comment
/// and picture blocks inserted after STREAMINFO. Any structural
/// surprise returns the audio untouched — a song is never lost over
/// its tags.
enum NcmTagWriter {
    static func tagged(_ song: NcmDecoder.Song) -> Data {
        switch song.format {
        case "mp3": return tagMP3(song)
        case "flac": return tagFLAC(song)
        default: return song.audio
        }
    }

    // MARK: - MP3 / ID3v2.3

    private static func tagMP3(_ song: NcmDecoder.Song) -> Data {
        var frames = Data()
        func textFrame(_ id: String, _ value: String) {
            guard !value.isEmpty else { return }
            var payload = Data([0x03]) // UTF-8
            payload += Data(value.utf8)
            frames += frame(id, payload)
        }
        textFrame("TIT2", song.title)
        textFrame("TPE1", song.artist)
        textFrame("TALB", song.album)
        if let cover = song.cover, !cover.isEmpty {
            var payload = Data([0x03])
            payload += Data(song.coverMIME.utf8)
            payload.append(0x00)
            payload.append(0x03) // front cover
            payload.append(0x00) // empty description
            payload += cover
            frames += frame("APIC", payload)
        }
        guard !frames.isEmpty else { return song.audio }
        var out = Data("ID3".utf8)
        out += Data([0x03, 0x00, 0x00])
        out += syncSafe(frames.count)
        out += frames
        out += stripID3(song.audio)
        return out
    }

    private static func frame(_ id: String, _ payload: Data) -> Data {
        var out = Data(id.utf8)
        out += u32be(payload.count)
        out += Data([0x00, 0x00])
        out += payload
        return out
    }

    /// Removes an existing ID3v2 tag if the audio already carries one.
    private static func stripID3(_ audio: Data) -> Data {
        guard audio.count >= 10, Array(audio[0..<3]) == [UInt8]("ID3".utf8) else { return audio }
        let sizeBytes = audio[6..<10]
        guard sizeBytes.allSatisfy({ $0 < 0x80 }) else { return audio }
        var size = 0
        for b in sizeBytes { size = (size << 7) | Int(b) }
        var total = 10 + size
        if audio[5] & 0x10 != 0 { total += 10 } // footer present
        guard total <= audio.count else { return audio }
        return audio.subdata(in: total..<audio.count)
    }

    // MARK: - FLAC metadata blocks

    private static func tagFLAC(_ song: NcmDecoder.Song) -> Data {
        let audio = song.audio
        guard audio.count >= 8, Array(audio[0..<4]) == [UInt8]("fLaC".utf8) else { return audio }
        // Walk the existing blocks to find where they end.
        var offset = 4
        var lastBlockEnd = -1
        while offset + 4 <= audio.count {
            let header = audio[offset]
            let length = Int(audio[offset + 1]) << 16 | Int(audio[offset + 2]) << 8 | Int(audio[offset + 3])
            offset += 4 + length
            if offset > audio.count { return audio }
            lastBlockEnd = offset
            if header & 0x80 != 0 { break }
        }
        guard lastBlockEnd > 0 else { return audio }

        var comment = Data()
        let vendor = Data("MusicBridge".utf8)
        comment += u32le(vendor.count); comment += vendor
        var entries: [Data] = []
        for (key, value) in [("TITLE", song.title), ("ARTIST", song.artist), ("ALBUM", song.album)] where !value.isEmpty {
            entries.append(Data("\(key)=\(value)".utf8))
        }
        comment += u32le(entries.count)
        for entry in entries { comment += u32le(entry.count); comment += entry }

        var blocks: [(type: UInt8, payload: Data)] = [(4, comment)]
        if let cover = song.cover, !cover.isEmpty {
            var picture = u32be(3) // front cover
            let mime = Data(song.coverMIME.utf8)
            picture += u32be(mime.count); picture += mime
            picture += u32be(0) // empty description
            picture += u32be(0); picture += u32be(0); picture += u32be(0); picture += u32be(0)
            picture += u32be(cover.count); picture += cover
            blocks.append((6, picture))
        }

        var out = Data(audio[0..<lastBlockEnd])
        // The previously-last block is no longer last.
        out[4 + blockHeaderIndex(ofLastBlockIn: audio, endingAt: lastBlockEnd)] &= 0x7F
        for (index, block) in blocks.enumerated() {
            let isLast = index == blocks.count - 1
            out.append((isLast ? 0x80 : 0x00) | block.type)
            out += u24be(block.payload.count)
            out += block.payload
        }
        out += audio.subdata(in: lastBlockEnd..<audio.count)
        return out
    }

    /// Byte offset of the header of the block that ends at `end`.
    private static func blockHeaderIndex(ofLastBlockIn audio: Data, endingAt end: Int) -> Int {
        var offset = 4
        var headerIndex = 4
        while offset + 4 <= end {
            headerIndex = offset
            let length = Int(audio[offset + 1]) << 16 | Int(audio[offset + 2]) << 8 | Int(audio[offset + 3])
            offset += 4 + length
        }
        return headerIndex - 4 // relative to just after "fLaC"
    }

    // MARK: - Byte helpers

    private static func u32be(_ value: Int) -> Data {
        Data([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func u24be(_ value: Int) -> Data {
        Data([UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private static func u32le(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    private static func syncSafe(_ value: Int) -> Data {
        Data([UInt8((value >> 21) & 0x7F), UInt8((value >> 14) & 0x7F), UInt8((value >> 7) & 0x7F), UInt8(value & 0x7F)])
    }
}
