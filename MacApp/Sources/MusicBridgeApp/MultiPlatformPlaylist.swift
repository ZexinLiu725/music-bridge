import Foundation

/// Playlist parsers for QQ Music and Kugou, producing the same
/// PlaylistSelection the NetEase parser produces so everything downstream
/// (catalog matching, the download queue, device import) stays unchanged.
/// Both endpoints were verified anonymously: QQ returns the full track
/// list as JSON; Kugou embeds its list in the playlist page HTML.
extension PlaylistSelection {

    // MARK: QQ Music

    static func qq(url: String) async throws -> PlaylistSelection {
        guard PlaylistSource.identify(url) == .qq, let input = PlaylistSource.extractURL(url) else {
            throw PlaylistLibraryError.invalidPlaylist
        }
        let raw = input.absoluteString
        let id = firstMatch(in: raw, patterns: [
            "/playlist/(\\d+)", "/playsquare/(\\d+)", "[?&]disstid=(\\d+)", "[?&]id=(\\d+)"
        ])
        guard let disstid = id, !disstid.isEmpty else { throw PlaylistLibraryError.invalidPlaylist }

        var components = URLComponents(string: "https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "onlysong", value: "0"),
            URLQueryItem(name: "disstid", value: disstid),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "loginUin", value: "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "yqq"),
            URLQueryItem(name: "needNewCode", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("https://y.qq.com/n/ryqq/playlist/\(disstid)", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cdlist = root["cdlist"] as? [[String: Any]], let cd = cdlist.first,
              let name = cd["dissname"] as? String, !name.isEmpty,
              let songlist = cd["songlist"] as? [[String: Any]], !songlist.isEmpty else {
            throw PlaylistLibraryError.invalidPlaylist
        }
        let tracks: [PlaylistSong] = songlist.compactMap { song in
            guard let title = (song["songname"] as? String) ?? (song["name"] as? String), !title.isEmpty else { return nil }
            let mid = (song["songmid"] as? String) ?? (song["mid"] as? String)
            let singers = (song["singer"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let interval = (song["interval"] as? NSNumber)?.intValue
            return PlaylistSong(title: title, artist: singers.joined(separator: " & "),
                                durationMs: interval.map { $0 * 1000 }, platformID: mid)
        }
        guard !tracks.isEmpty else { throw PlaylistLibraryError.incompletePlaylist }
        let cover = (cd["logo"] as? String)
            .map { $0.replacingOccurrences(of: "http://", with: "https://") }
            .flatMap(URL.init(string:)) ?? URL(string: "https://y.qq.com")!
        return PlaylistSelection(id: disstid, name: name,
                                 sourceURL: URL(string: "https://y.qq.com/n/ryqq/playlist/\(disstid)")!,
                                 coverURL: cover, tracks: tracks, sourceTrackCount: tracks.count)
    }

    // MARK: Kugou

    static func kugou(url: String) async throws -> PlaylistSelection {
        guard PlaylistSource.identify(url) == .kugou, let input = PlaylistSource.extractURL(url) else {
            throw PlaylistLibraryError.invalidPlaylist
        }
        let raw = input.absoluteString
        guard let specialID = firstMatch(in: raw, patterns: ["collection_3_(\\d+)", "special/single/(\\d+)"]),
              !specialID.isEmpty else { throw PlaylistLibraryError.invalidPlaylist }
        // The share URL itself is a working playlist page; only rebuild the
        // canonical address when the pasted link is some other Kugou form.
        let pageURL = raw.contains("collection_") ? input
            : URL(string: "https://www.kugou.com/yy/special/single/collection_3_\(specialID)_1_0.html")!
        var request = URLRequest(url: pageURL)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw PlaylistLibraryError.invalidPlaylist
        }
        // Each row: <a title="歌手 - 歌名" ... data="HASH|album_id">
        let rowPattern = "title=\"([^\"]+)\"[^>]*data=\"([A-F0-9]{32})\\|([0-9]+)\""
        guard let regex = try? NSRegularExpression(pattern: rowPattern) else {
            throw PlaylistLibraryError.invalidPlaylist
        }
        let range = NSRange(html.startIndex..., in: html)
        var tracks: [PlaylistSong] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: range) {
            guard let titleRange = Range(match.range(at: 1), in: html),
                  let hashRange = Range(match.range(at: 2), in: html) else { continue }
            let combined = unescapeHTML(String(html[titleRange]))
            let hash = String(html[hashRange])
            guard seen.insert(hash).inserted else { continue }
            // Kugou writes "歌手 - 歌名" (artist first), the reverse of the
            // "title - artist" export format used elsewhere in the app.
            let artist: String
            let title: String
            if let separator = combined.range(of: " - ") {
                artist = String(combined[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                title = String(combined[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                artist = ""
                title = combined
            }
            guard !title.isEmpty else { continue }
            tracks.append(PlaylistSong(title: title, artist: artist, platformID: hash))
        }
        guard !tracks.isEmpty else { throw PlaylistLibraryError.incompletePlaylist }
        let name = firstMatch(in: html, patterns: ["名称：</span>([^<]+)"])
            .map { unescapeHTML($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? "酷狗歌单"
        return PlaylistSelection(id: specialID, name: name.isEmpty ? "酷狗歌单" : name,
                                 sourceURL: URL(string: "https://www.kugou.com/yy/special/single/collection_3_\(specialID)_1_0.html")!,
                                 coverURL: URL(string: "https://www.kugou.com")!,
                                 tracks: tracks, sourceTrackCount: tracks.count)
    }

    // MARK: Helpers

    private static func firstMatch(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let group = Range(match.range(at: 1), in: text) {
                return String(text[group])
            }
        }
        return nil
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
