import Foundation

/// Downloads straight from NetEase by a track's exact ID from the user's
/// own playlist, so there is no fuzzy matching involved at all. Anonymous
/// requests get whatever the account-less API grants (up to about
/// 320 kbps MP3, free songs only). Once the user signs in, requests carry
/// their session and ask for the best tier the account is entitled to —
/// lossless FLAC first — which makes this a first-class channel rather
/// than a fallback. Trial clips handed to accounts without the rights for
/// a song are rejected, never saved. Every file fetched this way is
/// tagged with its source in the job ledger.
struct FallbackSourceClient: Sendable {
    let cookieHeader: String?

    init(cookieHeader: String? = nil) {
        self.cookieHeader = cookieHeader
    }

    var signedIn: Bool {
        guard let cookieHeader else { return false }
        return !cookieHeader.isEmpty
    }

    struct Fetched: Sendable {
        let fileName: String
        let bitrateKbps: Int?
        let format: String
    }

    enum FallbackError: LocalizedError {
        case noStream
        case emptyDownload

        var errorDescription: String? {
            switch self {
            case .noStream: return "网易云没有返回可下载的音频（付费歌曲可能需要黑胶 VIP）。"
            case .emptyDownload: return "网易云返回的文件不完整。"
            }
        }
    }

    func fetch(neteaseID: String, title: String, artist: String, into folder: URL) async throws -> Fetched {
        let stream = try await resolveStream(neteaseID: neteaseID)
        var download = URLRequest(url: Self.secureURL(stream.url))
        download.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        download.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if signedIn { download.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        download.timeoutInterval = 60
        let (audio, _) = try await URLSession.shared.data(for: download)
        guard audio.count > 32_768 else { throw FallbackError.emptyDownload }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = Self.fileName(title: title, artist: artist, format: stream.format)
        try audio.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        return Fetched(fileName: fileName, bitrateKbps: stream.bitrate.map { $0 / 1000 }, format: stream.format)
    }

    private struct StreamInfo {
        let url: URL
        let bitrate: Int?
        let format: String
    }

    /// Best-effort explanation for why a track has no downloadable stream,
    /// used to annotate the job ledger when a fetch could not happen. The
    /// song record's fee flag separates the cases: VIP-only tracks, paid
    /// tracks, and tracks NetEase cannot serve at all (licensing) — the
    /// last of these must never be misreported as a membership problem.
    func unavailabilityNote(neteaseID: String) async -> String {
        var components = URLComponents(string: "https://music.163.com/api/song/detail")!
        components.queryItems = [URLQueryItem(name: "ids", value: "[\(neteaseID)]")]
        guard let data = try? await get(components.url!) else { return "网易云没有返回可下载的音频" }
        struct Envelope: Decodable {
            struct Song: Decodable { let fee: Int? }
            let songs: [Song]
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let fee = envelope.songs.first?.fee else { return "网易云没有返回可下载的音频" }
        switch fee {
        case 1: return "需要黑胶 VIP 才能下载"
        case 8: return "付费歌曲，需要黑胶 VIP 或单曲购买"
        case 0: return "网易云未提供这首歌的音频（版权限制）"
        default: return "网易云没有返回可下载的音频"
        }
    }

    private func resolveStream(neteaseID: String) async throws -> StreamInfo {
        if signedIn {
            // Ask for the best the account may have: lossless first, then
            // the top MP3 tier, then the legacy endpoint as a last resort.
            if let info = try? await resolveV1(neteaseID: neteaseID, level: "lossless", encodeType: "flac") { return info }
            if let info = try? await resolveV1(neteaseID: neteaseID, level: "exhigh", encodeType: "mp3") { return info }
            if let info = try? await resolveLegacy(neteaseID: neteaseID) { return info }
            throw FallbackError.noStream
        }
        // Legacy first for anonymous requests: it is the endpoint that
        // historically answers them; the v1 endpoint often rejects them.
        if let info = try? await resolveLegacy(neteaseID: neteaseID) { return info }
        if let info = try? await resolveV1(neteaseID: neteaseID, level: "exhigh", encodeType: "mp3") { return info }
        throw FallbackError.noStream
    }

    private func resolveV1(neteaseID: String, level: String, encodeType: String) async throws -> StreamInfo {
        var components = URLComponents(string: "https://music.163.com/api/song/enhance/player/url/v1")!
        components.queryItems = [
            URLQueryItem(name: "id", value: neteaseID),
            URLQueryItem(name: "level", value: level),
            URLQueryItem(name: "encodeType", value: encodeType)
        ]
        let data = try await get(components.url!)
        struct Envelope: Decodable {
            struct Trial: Decodable {}
            struct Item: Decodable {
                let url: String?
                let br: Int?
                let type: String?
                let freeTrialInfo: Trial?
            }
            let data: [Item]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        // A non-null freeTrialInfo means the account only gets a short
        // preview clip of this song — that is not a download.
        guard let item = envelope.data.first, item.freeTrialInfo == nil,
              let raw = item.url, let url = URL(string: raw) else {
            throw FallbackError.noStream
        }
        return StreamInfo(url: url, bitrate: item.br,
                          format: (item.type ?? encodeType).lowercased())
    }

    private func resolveLegacy(neteaseID: String) async throws -> StreamInfo {
        var components = URLComponents(string: "https://music.163.com/api/song/enhance/player/url")!
        components.queryItems = [
            URLQueryItem(name: "ids", value: "[\(neteaseID)]"),
            URLQueryItem(name: "br", value: "320000")
        ]
        let data = try await get(components.url!)
        struct Envelope: Decodable {
            struct Item: Decodable { let url: String?; let br: Int? }
            let data: [Item]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let item = envelope.data.first, let raw = item.url, let url = URL(string: raw) else {
            throw FallbackError.noStream
        }
        return StreamInfo(url: url, bitrate: item.br, format: "mp3")
    }

    /// NetEase answers with plain-http CDN links, which App Transport
    /// Security refuses to load. The same CDN hosts serve the identical
    /// path over https, so upgrade the scheme before downloading.
    private static func secureURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        if signedIn { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func fileName(title: String, artist: String, format: String) -> String {
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "/", with: " ")
                .replacingOccurrences(of: ":", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = artist.isEmpty ? clean(title) : "\(clean(title)) - \(clean(artist))"
        return (base.isEmpty ? "未命名" : base) + (format == "flac" ? ".flac" : ".mp3")
    }
}
