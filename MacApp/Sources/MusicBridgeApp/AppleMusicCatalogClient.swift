import Foundation

struct CatalogTrackQuery: Sendable {
    let title: String
    let artist: String

    var displayName: String {
        artist.isEmpty ? title : "\(title) · \(artist)"
    }
}

struct CatalogMatchResult: Sendable {
    let urls: [String]
    let matched: Int
    let skipped: [CatalogTrackQuery]
    let tracks: [PlaylistSong]
    /// The source queries behind `tracks`, in the same order, so callers
    /// can trace a matched entry back to its source-platform track.
    let matchedQueries: [CatalogTrackQuery]
    let reviews: [CatalogReviewCandidate]
}

/// The closest catalog candidate for a song that was not confident enough
/// to download automatically. Kept so the skip is reviewable instead of
/// silent: the user can see what was rejected and why, and pick it manually.
struct CatalogReviewCandidate: Sendable {
    let query: CatalogTrackQuery
    let candidateTitle: String
    let candidateArtist: String
    let candidateAlbum: String?
    let candidateURL: String
    let candidateDurationMs: Int?
    let score: Double
    let reason: String
}

enum AppleMusicCatalogError: LocalizedError {
    case tokenUnavailable
    case invalidResponse
    case serviceUnavailable(Int)
    case noMatches

    var errorDescription: String? {
        switch self {
        case .tokenUnavailable:
            return "无法取得 Apple Music 搜索凭证。"
        case .invalidResponse:
            return "Apple Music 搜索返回了无法识别的数据。"
        case .serviceUnavailable(let status):
            return "Apple Music 搜索暂时不可用（HTTP \(status)）。"
        case .noMatches:
            return "没有找到可下载的 Apple Music 单曲。"
        }
    }
}

/// Resolves the title/artist lines exported by GoMusic into public Apple Music
/// song URLs. Only high-confidence matches are returned, so an ambiguous
/// version is skipped instead of being downloaded silently.
struct AppleMusicCatalogClient: Sendable {
    private let storefront = "cn"
    private let language = "zh-CN"

    func match(
        export: PlaylistExport,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> CatalogMatchResult {
        let queries = parseQueries(export.text)
        guard !queries.isEmpty else { throw AppleMusicCatalogError.noMatches }

        let token = try await fetchDeveloperToken()
        var urls: [String] = []
        var tracks: [PlaylistSong] = []
        var matchedQueries: [CatalogTrackQuery] = []
        var skipped: [CatalogTrackQuery] = []
        var reviews: [CatalogReviewCandidate] = []
        // Queries are parsed from the export text in playlist order, so the
        // selection's tracks line up index-by-index and can supply the
        // expected duration for each query. If the counts ever disagree,
        // duration checks simply stay off.
        let playlistTracks = export.playlist?.tracks ?? []
        let durationsAligned = playlistTracks.count == queries.count
        var seen = Set<String>()
        var lastSearchError: Error?
        // A shared album requires the same album, not merely a similar song
        // from a single, compilation, or another edition.
        let requiredAlbum = export.playlist?.sourceURL.path == "/album" ? export.playlist?.name : nil

        for (index, query) in queries.enumerated() {
            try Task.checkCancellation()
            do {
                let expectedDuration = durationsAligned ? playlistTracks[index].durationMs : nil
                let outcome = try await search(query: query, token: token, requiredAlbum: requiredAlbum, expectedDurationMs: expectedDuration)
                if let match = outcome.song {
                    let url = match.url
                    if seen.insert(url).inserted { urls.append(url) }
                    tracks.append(PlaylistSong(title: match.title, artist: match.artist, album: match.album))
                    matchedQueries.append(query)
                } else {
                    skipped.append(query)
                    if let review = outcome.review { reviews.append(review) }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                lastSearchError = error
                skipped.append(query)
            }
            await progress(index + 1, queries.count)
        }

        if urls.isEmpty {
            throw lastSearchError ?? AppleMusicCatalogError.noMatches
        }
        return CatalogMatchResult(urls: urls, matched: urls.count, skipped: skipped, tracks: tracks, matchedQueries: matchedQueries, reviews: reviews)
    }

    private func fetchDeveloperToken() async throws -> String {
        var homeRequest = URLRequest(url: URL(string: "https://music.apple.com/\(storefront)")!)
        homeRequest.setValue("Music Bridge/1.0", forHTTPHeaderField: "User-Agent")
        let (homeData, homeResponse) = try await URLSession.shared.data(for: homeRequest)
        guard let homeHTTP = homeResponse as? HTTPURLResponse,
              (200..<400).contains(homeHTTP.statusCode) else {
            throw AppleMusicCatalogError.invalidResponse
        }
        guard let home = String(data: homeData, encoding: .utf8),
              let scriptPath = home.range(of: "/assets/index~[^\"']+\\.js", options: .regularExpression).map({ String(home[$0]) }) else {
            throw AppleMusicCatalogError.tokenUnavailable
        }

        var scriptRequest = URLRequest(url: URL(string: "https://music.apple.com\(scriptPath)")!)
        scriptRequest.setValue("Music Bridge/1.0", forHTTPHeaderField: "User-Agent")
        let (scriptData, scriptResponse) = try await URLSession.shared.data(for: scriptRequest)
        guard let scriptHTTP = scriptResponse as? HTTPURLResponse,
              (200..<400).contains(scriptHTTP.statusCode),
              let script = String(data: scriptData, encoding: .utf8),
              let token = script.range(of: "eyJ[A-Za-z0-9-_=]+\\.[A-Za-z0-9-_=]+\\.[A-Za-z0-9-_=]+", options: .regularExpression).map({ String(script[$0]) }) else {
            throw AppleMusicCatalogError.tokenUnavailable
        }
        return token
    }

    private struct SearchOutcome {
        let song: CatalogSong?
        let review: CatalogReviewCandidate?
    }

    private func search(query: CatalogTrackQuery, token: String, requiredAlbum: String?, expectedDurationMs: Int?) async throws -> SearchOutcome {
        // One phrasing often misses songs that are in the catalog: the raw
        // NetEase title may carry version suffixes ("（国）", "(Live)") or the
        // artist may be listed under a different name, which buries the right
        // hit or pushes it past the result limit. Fall back to simpler terms
        // before giving up on a song; the candidate scoring in searchOnce is
        // what keeps these extra attempts honest.
        let core = Self.coreTitle(query.title)
        var terms: [String] = []
        func addTerm(_ term: String) {
            let cleaned = term.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty, !terms.contains(cleaned) { terms.append(cleaned) }
        }
        addTerm("\(query.title) \(query.artist)")
        if core != query.title { addTerm("\(core) \(query.artist)") }
        if !query.artist.isEmpty { addTerm(query.title) }
        if core != query.title { addTerm(core) }
        if !query.artist.isEmpty { addTerm(query.artist) }
        var bestRejected: (song: CatalogSong, reason: String)?
        for (index, term) in terms.enumerated() {
            let outcome = try await searchOnce(term: term, limit: index == 0 ? 10 : 25,
                                               query: query, token: token, requiredAlbum: requiredAlbum,
                                               expectedDurationMs: expectedDurationMs)
            if let hit = outcome.song { return SearchOutcome(song: hit, review: nil) }
            if let rejected = outcome.rejected, let reason = outcome.reason,
               rejected.score > (bestRejected?.song.score ?? -1) {
                bestRejected = (rejected, reason)
            }
        }
        if let bestRejected {
            let review = CatalogReviewCandidate(query: query,
                                                candidateTitle: bestRejected.song.title,
                                                candidateArtist: bestRejected.song.artist,
                                                candidateAlbum: bestRejected.song.album,
                                                candidateURL: bestRejected.song.url,
                                                candidateDurationMs: bestRejected.song.durationMs,
                                                score: bestRejected.song.score,
                                                reason: bestRejected.reason)
            return SearchOutcome(song: nil, review: review)
        }
        return SearchOutcome(song: nil, review: nil)
    }

    /// A title with its version decorations removed: parenthesised segments
    /// and a trailing " - ..." suffix. Used only to build fallback search
    /// terms; candidate scoring always sees the original title.
    static func coreTitle(_ title: String) -> String {
        var text = title.replacingOccurrences(of: "\\([^)]*\\)|\\[[^]]*\\]|（[^）]*）|【[^】]*】", with: "", options: .regularExpression)
        if let dash = text.range(of: " - ") { text = String(text[..<dash.lowerBound]) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchOnce(term: String, limit: Int, query: CatalogTrackQuery, token: String, requiredAlbum: String?, expectedDurationMs: Int?) async throws -> (song: CatalogSong?, rejected: CatalogSong?, reason: String?) {
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "l", value: language)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        request.setValue("Music Bridge/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppleMusicCatalogError.invalidResponse }
        guard http.statusCode == 200 else { throw AppleMusicCatalogError.serviceUnavailable(http.statusCode) }
        let envelope = try JSONDecoder().decode(CatalogSearchEnvelope.self, from: data)
        let candidates = envelope.results.songs?.data ?? []
        // Candidates that pass the text gates, each tagged with whether it
        // also passes the duration gate. A candidate whose duration
        // disagrees with the NetEase original by more than 3 seconds is a
        // different cut (radio edit, extended mix, wrong recording) no
        // matter how well the text matches, so it can never be accepted
        // automatically; it is still kept as the best rejected candidate
        // for the review list.
        let scored: [(song: CatalogSong, durationOK: Bool)] = candidates.compactMap { candidate in
            guard let url = candidate.attributes.url else { return nil }
            if let requiredAlbum {
                guard let album = candidate.attributes.albumName,
                      normalize(album) == normalize(requiredAlbum) else { return nil }
            }
            let titleScore = similarity(query.title, candidate.attributes.name)
            let artistScore = artistSimilarity(query.artist, candidate.attributes.artistName)
            // The artist check also passes when the query artist is
            // credited inside the candidate's title ("(feat. …)"): some
            // listings credit the featured singer, not the album artist.
            let creditedInTitle = query.artist.count >= 2
                && candidate.attributes.name.lowercased().contains(query.artist.lowercased())
            guard titleScore >= 0.70,
                  Self.isLiveVersion(query.title) == Self.isLiveVersion(candidate.attributes.name + " " + (candidate.attributes.albumName ?? "")),
                  query.artist.isEmpty || artistScore >= 0.45 || creditedInTitle else { return nil }
            let song = CatalogSong(
                title: candidate.attributes.name,
                artist: candidate.attributes.artistName,
                album: candidate.attributes.albumName,
                url: url,
                score: score(query: query, candidate: candidate),
                durationMs: candidate.attributes.durationInMillis
            )
            let durationOK: Bool
            if let expected = expectedDurationMs, let actual = song.durationMs {
                durationOK = abs(actual - expected) <= 3000
            } else {
                durationOK = true
            }
            return (song, durationOK)
        }
        if let hit = scored.filter({ $0.durationOK && $0.song.score >= 0.72 }).max(by: { $0.song.score < $1.song.score })?.song {
            return (hit, nil, nil)
        }
        guard let best = scored.max(by: { $0.song.score < $1.song.score }) else { return (nil, nil, nil) }
        let reason: String
        if !best.durationOK, let expected = expectedDurationMs, let actual = best.song.durationMs {
            reason = "时长差约 \(abs(actual - expected) / 1000) 秒"
        } else {
            reason = "相似度不足"
        }
        return (nil, best.song, reason)
    }

    static func isLiveVersion(_ title: String) -> Bool {
        title.range(of: "(?i)\\blive\\b|现场|現場|演唱会|演唱會", options: .regularExpression) != nil
    }

    private func score(query: CatalogTrackQuery, candidate: CatalogSearchSong) -> Double {
        let title = similarity(query.title, candidate.attributes.name)
        let artist = artistSimilarity(query.artist, candidate.attributes.artistName)
        let exactBonus = normalize(query.title) == normalize(candidate.attributes.name) ? 0.12 : 0
        let variantPenalty = versionMismatch(query.title, candidate.attributes.name) ? 0.35 : 0
        return min(1, max(0, title * 0.68 + artist * 0.32 + exactBonus - variantPenalty))
    }

    private func versionMismatch(_ lhs: String, _ rhs: String) -> Bool {
        // A remaster is the same recording, not a different version, so it is
        // deliberately absent here: penalising it skipped most older catalog
        // songs, whose only editions in the store are remasters.
        let markers = ["live", "remix", "acoustic", "demo", "karaoke", "instrumental", "sped up", "现场", "混音"]
        let left = lhs.lowercased()
        let right = rhs.lowercased()
        return markers.contains { marker in
            left.contains(marker) != right.contains(marker)
        }
    }

    private func artistSimilarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty else { return 0.68 }
        let full = similarity(lhs, rhs)
        // Split on whitespace and parentheses too: bilingual credits such
        // as "Rui En 芮恩" or "夢飛船 (Dreamz FM)" arrive as one string, and
        // comparing them whole scores near zero even when a part matches
        // exactly.
        let queryParts = lhs.split(whereSeparator: { "&,、/()（） ".contains($0) }).map(String.init)
        let candidateParts = rhs.split(whereSeparator: { "&,、/()（） ".contains($0) }).map(String.init)
        let partBest = queryParts.map { part in
            candidateParts.map { similarity(part, $0) }.max() ?? 0
        }.reduce(0, +) / Double(max(1, queryParts.count))
        return max(full, partBest)
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(normalize(lhs))
        let right = Array(normalize(rhs))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let maxLength = max(left.count, right.count)
        var previous = Array(0...right.count)
        for (row, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = row + 1
            for (column, rightCharacter) in right.enumerated() {
                let cost = leftCharacter == rightCharacter ? 0 : 1
                current[column + 1] = min(
                    previous[column + 1] + 1,
                    current[column] + 1,
                    previous[column] + cost
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(maxLength)
    }

    private func normalize(_ value: String) -> String {
        // Fold Traditional to Simplified first: the same song is often
        // listed under different scripts by the two catalogs (《梦游涂鸦街》
        // vs 《夢遊塗鸦街》), and edit distance treats every script variant
        // as a different character.
        let mutable = NSMutableString(string: value)
        _ = CFStringTransform(mutable, nil, "Traditional-Simplified" as CFString, false)
        let simplified = mutable as String
        var text = simplified
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        text = text.replacingOccurrences(of: "feat.", with: " ")
        text = text.replacingOccurrences(of: "featuring", with: " ")
        text = text.replacingOccurrences(of: "\\([^)]*\\)|\\[[^]]*\\]|（[^）]*）|【[^】]*】", with: " ", options: .regularExpression)
        return text.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .split(whereSeparator: { $0 == " " })
            .joined()
    }

    private func parseQueries(_ text: String) -> [CatalogTrackQuery] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            if let separator = line.range(of: " - ") {
                let title = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                let artist = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return nil }
                return CatalogTrackQuery(title: title, artist: artist)
            }
            return CatalogTrackQuery(title: line, artist: "")
        }
    }
}

private struct CatalogSearchEnvelope: Decodable {
    let results: CatalogSearchResults
}

private struct CatalogSearchResults: Decodable {
    let songs: CatalogSongResults?
}

private struct CatalogSongResults: Decodable {
    let data: [CatalogSearchSong]
}

private struct CatalogSearchSong: Decodable {
    let attributes: CatalogSearchAttributes
}

private struct CatalogSearchAttributes: Decodable {
    let name: String
    let artistName: String
    let url: String?
    let albumName: String?
    let durationInMillis: Int?
}

private struct CatalogSong: Sendable {
    let title: String
    let artist: String
    let album: String?
    let url: String
    let score: Double
    let durationMs: Int?
}
