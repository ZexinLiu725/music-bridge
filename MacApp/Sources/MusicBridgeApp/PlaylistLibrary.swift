import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PlaylistSong: Codable, Sendable, Equatable {
    let title: String
    let artist: String
    var album: String? = nil
    /// NetEase track id and duration (milliseconds, the `dt` field), kept so
    /// catalog matching can verify duration and later stages can refer back
    /// to the source track. Optional: selections saved by older builds
    /// decode unchanged without them.
    var neteaseID: String? = nil
    var durationMs: Int? = nil
    /// The track's ID on its home platform for non-NetEase sources
    /// (QQ songmid, Kugou hash). NetEase tracks keep using neteaseID.
    var platformID: String? = nil
}

struct PlaylistSelection: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let sourceURL: URL
    let coverURL: URL
    var tracks: [PlaylistSong]
    var sourceTrackCount: Int? = nil

    static func netease(url: String) async throws -> PlaylistSelection {
        guard PlaylistSource.identify(url) == .netease, let input = PlaylistSource.extractURL(url) else {
            throw PlaylistLibraryError.invalidPlaylist
        }
        var resolved = input
        if input.host == "163cn.tv" {
            let (_, response) = try await URLSession.shared.data(from: input)
            guard let final = response.url, final.host == "music.163.com" else { throw PlaylistLibraryError.invalidPlaylist }
            resolved = final
        }
        let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
        let fragment = URLComponents(string: "https://music.163.com/" + (resolved.fragment ?? ""))
        guard let id = (components?.queryItems ?? fragment?.queryItems)?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty, id.allSatisfy(\.isNumber) else { throw PlaylistLibraryError.invalidPlaylist }
        let path = resolved.path + "/" + (resolved.fragment ?? "")
        if path.contains("album") {
            let data = try await request(URL(string: "https://music.163.com/api/v1/album/\(id)")!)
            return try parseAlbum(data, id: id)
        }
        guard path.contains("playlist") else { throw PlaylistLibraryError.invalidPlaylist }
        let data = try await request(URL(string: "https://music.163.com/api/v6/playlist/detail?id=\(id)&n=10000&s=0")!)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["code"] as? Int == 200, let playlist = envelope["playlist"] as? [String: Any],
              let name = playlist["name"] as? String,
              let coverString = playlist["coverImgUrl"] as? String,
              let cover = URL(string: coverString.replacingOccurrences(of: "http://", with: "https://")),
              let items = playlist["trackIds"] as? [[String: Any]] else { throw PlaylistLibraryError.invalidPlaylist }
        let ids = items.compactMap { ($0["id"] as? NSNumber)?.stringValue }
        guard !ids.isEmpty, ids.count == items.count,
              ids.count == playlist["trackCount"] as? Int else { throw PlaylistLibraryError.incompletePlaylist }
        var songs: [String: PlaylistSong] = [:]
        for start in stride(from: 0, to: ids.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(ids[start..<min(start + 100, ids.count)])
            var detail = URLComponents(string: "https://music.163.com/api/song/detail")!
            detail.queryItems = [URLQueryItem(name: "ids", value: "[" + batch.joined(separator: ",") + "]")]
            let response = try await request(detail.url!)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  object["code"] as? Int == 200,
                  let tracks = object["songs"] as? [[String: Any]] else { throw PlaylistLibraryError.incompletePlaylist }
            for track in tracks {
                guard let trackID = (track["id"] as? NSNumber)?.stringValue,
                      let title = track["name"] as? String,
                      let artists = track["artists"] as? [[String: Any]] else { continue }
                songs[trackID] = PlaylistSong(title: title, artist: artists.compactMap { $0["name"] as? String }.joined(separator: " & "),
                                              neteaseID: trackID, durationMs: (track["dt"] as? NSNumber)?.intValue)
            }
        }
        let ordered = ids.compactMap { songs[$0] }
        guard ordered.count == ids.count else { throw PlaylistLibraryError.incompletePlaylist }
        return PlaylistSelection(id: id, name: name, sourceURL: URL(string: "https://music.163.com/playlist?id=\(id)")!,
                                 coverURL: cover, tracks: ordered, sourceTrackCount: ordered.count)
    }

    static func parseAlbum(_ data: Data, id: String) throws -> PlaylistSelection {
        guard !id.isEmpty, id.allSatisfy(\.isNumber),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["code"] as? Int == 200, let album = envelope["album"] as? [String: Any],
              let actualID = (album["id"] as? NSNumber)?.stringValue, actualID == id,
              let name = album["name"] as? String, !name.isEmpty,
              let coverString = album["picUrl"] as? String,
              let cover = URL(string: coverString.replacingOccurrences(of: "http://", with: "https://")),
              let tracks = envelope["songs"] as? [[String: Any]],
              let count = album["size"] as? Int, count > 0, tracks.count == count else {
            throw PlaylistLibraryError.incompletePlaylist
        }
        let songs: [PlaylistSong] = tracks.compactMap { track in
            guard let title = track["name"] as? String, !title.isEmpty,
                  let artists = track["ar"] as? [[String: Any]] else { return nil }
            let artist = artists.compactMap { $0["name"] as? String }.joined(separator: " & ")
            guard !artist.isEmpty else { return nil }
            return PlaylistSong(title: title, artist: artist, album: name,
                                neteaseID: (track["id"] as? NSNumber)?.stringValue,
                                durationMs: (track["dt"] as? NSNumber)?.intValue)
        }
        guard songs.count == count else { throw PlaylistLibraryError.incompletePlaylist }
        return PlaylistSelection(id: id, name: name, sourceURL: URL(string: "https://music.163.com/album?id=\(id)")!,
                                 coverURL: cover, tracks: songs, sourceTrackCount: count)
    }

    private static func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PlaylistLibraryError.invalidPlaylist }
        return data
    }
}

enum PlaylistLibraryError: LocalizedError {
    case invalidPlaylist, incompletePlaylist, noLocalTracks, missingTools, conversionFailed, invalidPath
    var errorDescription: String? {
        switch self {
        case .invalidPlaylist: return "无法读取歌单或专辑，请检查分享链接。"
        case .incompletePlaylist: return "歌单或专辑歌曲信息不完整，已停止处理，避免导入错误内容。"
        case .noLocalTracks: return "没有找到属于这份歌单的本地歌曲，请先完成下载。"
        case .missingTools: return "歌单导入需要 FFmpeg 和 ffprobe，请先安装。"
        case .conversionFailed: return "歌单副本生成或校验失败，原文件已保留。"
        case .invalidPath: return "歌单路径无效，已停止处理。"
        }
    }
}

struct PreparedPlaylist: Sendable {
    let files: [(url: URL, root: URL)]
    let originals: [(url: URL, root: URL)]
    let missing: Int
}

/// Dedicated import copies retain original audio and tags; per-track artwork
/// is isolated so a playlist cover cannot become every song's cover.
struct PlaylistLibrary: Sendable {
    let root: URL

    private struct CachedFile: Codable, Equatable {
        let path: String
        let size: Int
        let modified: Date
        init(_ url: URL) throws {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate else { throw PlaylistLibraryError.invalidPath }
            self.path = url.path; self.size = size; self.modified = modified
        }
    }
    private struct Cache: Codable {
        let selection: PlaylistSelection
        let sources: [CachedFile]
        let outputs: [CachedFile]
        let base: URL
        let cover: URL
        let missing: Int
        var appearanceVersion: Int? = nil
    }

    func save(_ selection: PlaylistSelection) throws {
        let file = root.appendingPathComponent("work/playlists/selected.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(selection).write(to: file, options: .atomic)
    }

    func load() -> PlaylistSelection? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("work/playlists/selected.json")) else { return nil }
        return try? JSONDecoder().decode(PlaylistSelection.self, from: data)
    }

    func clearSelection() throws {
        let file = root.appendingPathComponent("work/playlists/selected.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("null".utf8).write(to: file, options: .atomic)
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func matches(_ song: PlaylistSong, tags: [String: String]) -> Bool {
        let title = normalized(tags["title"] ?? "")
        let artist = normalized(tags["artist"] ?? "")
        let expectedArtist = normalized(song.artist)
        if let album = song.album, normalized(tags["album"] ?? "") != normalized(album) { return false }
        return !title.isEmpty && title == normalized(song.title) && !artist.isEmpty && !expectedArtist.isEmpty
            && (artist == expectedArtist || artist.contains(expectedArtist) || expectedArtist.contains(artist))
    }

    static func folderName(_ selection: PlaylistSelection) -> String {
        let safe = selection.name.components(separatedBy: CharacterSet(charactersIn: "/\\:\0")).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(safe.prefix(70)) + " [" + selection.id + "]"
    }

    /// Device folder for a playlist import: the playlist's own name, made
    /// safe for FAT32, without the " [id]" suffix folderName adds.
    static func deviceFolderName(_ selection: PlaylistSelection) -> String {
        let illegal = CharacterSet(charactersIn: "/\\<>\"|?*").union(.controlCharacters)
        let safe = selection.name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = safe.hasSuffix(".") ? String(safe.dropLast()) : safe
        return String((trimmed.isEmpty ? "歌单" : trimmed).prefix(70))
    }

    /// "07. Song Name" for the track at a playlist position: a numeric
    /// prefix the source filename carries (its album track number) is
    /// replaced by the playlist ordinal, so folder order == playlist order.
    static func playlistFileStem(_ url: URL, ordinal: Int, width: Int) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: "^[0-9]+\\.\\s*", options: .regularExpression) {
            let rest = String(name[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { name = rest }
        }
        return String(format: "%0\(width)d. ", ordinal) + name
    }

    static func displayAlbumArtist(for selection: PlaylistSelection) -> String {
        let firstArtists = selection.tracks.map {
            $0.artist.components(separatedBy: " & ").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }.filter { !$0.isEmpty }
        let counts = Dictionary(grouping: firstArtists, by: { $0 }).mapValues(\.count)
        if let common = counts.max(by: { $0.value < $1.value }),
           common.value * 5 >= max(1, selection.tracks.count) * 4 { return common.key }
        return "精选歌单"
    }

    func customCover(for selection: PlaylistSelection) -> Data? {
        guard !selection.id.isEmpty, selection.id.allSatisfy(\.isNumber) else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent("work/playlists/artwork/\(selection.id).jpg"))
    }

    /// Stock firmware uses its own album/artwork database. Keep original album tags.
    func nativeFiles(for selection: PlaylistSelection?) throws -> (files: [(url: URL, root: URL)], missing: Int, unmatched: [PlaylistSong]) {
        let all = IPodImporter().audioFiles(in: root)
        guard let selection else {
            guard !all.isEmpty else { throw PlaylistLibraryError.noLocalTracks }
            return (all, 0, [])
        }
        let tagged = try all.map { (item: $0, tags: try metadata($0.url)) }
        var files: [(url: URL, root: URL)] = []
        var used = Set<String>()
        var unmatched: [PlaylistSong] = []
        var missing = max(0, (selection.sourceTrackCount ?? selection.tracks.count) - selection.tracks.count)
        for song in selection.tracks {
            let matches = tagged.filter { Self.matches(song, tags: $0.tags) }
            guard matches.count == 1 else { missing += 1; unmatched.append(song); continue }
            if used.insert(matches[0].item.url.path).inserted { files.append(matches[0].item) }
        }
        guard !files.isEmpty else { throw PlaylistLibraryError.noLocalTracks }
        return (files, missing, unmatched)
    }

    /// After a batch (playlist) download, the files in the batch folder carry
    /// each song's own album track number (amdl's "{SongNumer}"), so the
    /// folder cannot be browsed in playlist order. Renumber them by playlist
    /// order — the same numbering `prepare` applies on import — matching
    /// files to tracks by their embedded tags, not by the file names.
    /// Best effort: any failure leaves the downloads untouched.
    @discardableResult
    func renumberBatchFolder(for selection: PlaylistSelection) -> (renamed: Int, unmatched: Int) {
        guard let folderName = DownloaderRunner.sanitizedBatchFolder(selection.name) else { return (0, 0) }
        let fm = FileManager.default
        let downloadRoots = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("AM-DL") }
        guard let folder = downloadRoots.map({ $0.appendingPathComponent(folderName) })
            .first(where: { fm.fileExists(atPath: $0.path) }),
            let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return (0, 0) }
        let audioExtensions: Set<String> = ["m4a", "mp4", "mp3", "flac", "aac", "ogg", "opus", "wav"]
        let audio = entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return (0, 0) }
        // Oldest download first: duplicates (same title and artist) resolve in
        // the order the files landed, which is the order amdl got the URLs.
        let tagged: [(url: URL, tags: [String: String])] = audio
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhs < rhs
            }
            .compactMap { url in (try? metadata(url)).map { (url, $0) } }
        var used = Set<String>()
        var assignments: [(url: URL, ordinal: Int)] = []
        for song in selection.tracks {
            guard let candidate = tagged.first(where: { !used.contains($0.url.path) && Self.matches(song, tags: $0.tags) }) else { continue }
            used.insert(candidate.url.path)
            assignments.append((candidate.url, assignments.count + 1))
        }
        guard !assignments.isEmpty else { return (0, audio.count) }
        let width = assignments.count > 99 ? 3 : 2
        var staged: [(original: URL, temp: URL, dest: URL)] = []
        var renamed = 0
        do {
            for (index, assignment) in assignments.enumerated() {
                let stem = Self.playlistFileStem(assignment.url, ordinal: assignment.ordinal, width: width)
                let dest = folder.appendingPathComponent(stem + "." + assignment.url.pathExtension)
                if dest.standardizedFileURL.path == assignment.url.standardizedFileURL.path { renamed += 1; continue }
                let temp = folder.appendingPathComponent(".renumber-\(index)-\(ProcessInfo.processInfo.globallyUniqueString)")
                try fm.moveItem(at: assignment.url, to: temp)
                staged.append((assignment.url, temp, dest))
            }
            for item in staged {
                try fm.moveItem(at: item.temp, to: item.dest)
                renamed += 1
            }
        } catch {
            for item in staged.reversed() where fm.fileExists(atPath: item.temp.path) {
                try? fm.moveItem(at: item.temp, to: item.original)
            }
            return (renamed, audio.count - assignments.count)
        }
        return (renamed, audio.count - assignments.count)
    }

    /// Songs ordered the way renumbering left them: by the numeric prefix
    /// in each file name ("07. …"), unnumbered files last.
    static func orderedAudioFiles(_ urls: [URL]) -> [URL] {
        func ordinal(_ url: URL) -> Int {
            let stem = url.deletingPathExtension().lastPathComponent
            guard let dot = stem.firstIndex(of: "."), let value = Int(stem[..<dot]) else { return Int.max }
            return value
        }
        return urls.sorted { ordinal($0) != ordinal($1) ? ordinal($0) < ordinal($1) : $0.lastPathComponent < $1.lastPathComponent }
    }

    static func m3uContent(name: String, files: [URL], tracks: [PlaylistSong]) -> String {
        var lines = ["#EXTM3U", "#PLAYLIST:\(name)"]
        for url in files {
            let stem = url.deletingPathExtension().lastPathComponent
            let title = stem.range(of: "^[0-9]+\\.\\s*", options: .regularExpression).map { String(stem[$0.upperBound...]) } ?? stem
            let seconds = tracks.first { $0.title == title }?.durationMs.map { $0 / 1000 } ?? -1
            lines.append("#EXTINF:\(seconds),\(title)")
            lines.append(url.lastPathComponent)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Write a standard .m3u8 into the batch folder after a download, in
    /// playlist order, so the folder works in any player — not only via
    /// this app's iPod import.
    @discardableResult
    func writeM3U(for selection: PlaylistSelection) -> Int {
        guard let folderName = DownloaderRunner.sanitizedBatchFolder(selection.name) else { return 0 }
        let fm = FileManager.default
        let downloadRoots = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("AM-DL") }
        guard let folder = downloadRoots.map({ $0.appendingPathComponent(folderName) })
            .first(where: { fm.fileExists(atPath: $0.path) }),
              let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        let audioExtensions: Set<String> = ["m4a", "mp4", "mp3", "flac", "aac", "ogg", "opus", "wav"]
        let audio = entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return 0 }
        let ordered = Self.orderedAudioFiles(audio)
        let content = Self.m3uContent(name: selection.name, files: ordered, tracks: selection.tracks)
        do { try content.write(to: folder.appendingPathComponent(folderName + ".m3u8"), atomically: true, encoding: .utf8) } catch { return 0 }
        return ordered.count
    }

    func prepare(_ selection: PlaylistSelection, coverData: Data, coverMaxPixel: Int = 600,
                 progress: @Sendable (Int, Int, String) -> Void) throws -> PreparedPlaylist {
        // The prepared-cache identity includes the cover size: 600px output
        // is appearance 6; the 256px iPod size gets its own version so a
        // settings change never reuses covers rendered at the other size.
        let appearanceVersion = coverMaxPixel == 256 ? 7 : 6
        guard !selection.id.isEmpty, selection.id.allSatisfy(\.isNumber), !selection.name.isEmpty else { throw PlaylistLibraryError.invalidPlaylist }
        let service = IPodImporter()
        let all = service.audioFiles(in: root)
        var available: [(item: (url: URL, root: URL), tags: [String: String])] = []
        for (index, item) in all.enumerated() {
            progress(index, all.count, "核对本地歌曲归属")
            available.append((item, try metadata(item.url)))
        }
        var selected: [(item: (url: URL, root: URL), tags: [String: String])] = []
        var missing = max(0, (selection.sourceTrackCount ?? selection.tracks.count) - selection.tracks.count)
        for song in selection.tracks {
            let matches = available.filter { Self.matches(song, tags: $0.tags) }
            // Ambiguous versions must not be silently combined.
            guard matches.count == 1 else { missing += 1; continue }
            let match = matches[0]
            selected.append(match)
        }
        guard !selected.isEmpty else { throw PlaylistLibraryError.noLocalTracks }
        let cacheRoot = root.appendingPathComponent("work/playlist-imports/\(selection.id)")
        let cacheFile = cacheRoot.appendingPathComponent("prepared.json")
        let sources = try selected.map { try CachedFile($0.item.url) }
        if let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode(Cache.self, from: data),
           cache.selection == selection, cache.sources == sources, cache.missing == missing, cache.appearanceVersion == appearanceVersion,
           cache.outputs.count == selected.count,
           cache.base.resolvingSymlinksInPath().path.hasPrefix(cacheRoot.resolvingSymlinksInPath().path + "/"),
           cache.cover.resolvingSymlinksInPath().path.hasPrefix(cache.base.resolvingSymlinksInPath().path + "/"),
           (try? Data(contentsOf: cache.cover)) == coverData,
           cache.outputs.allSatisfy({ file in
               let url = URL(fileURLWithPath: file.path)
               return url.resolvingSymlinksInPath().path.hasPrefix(cache.base.resolvingSymlinksInPath().path + "/")
                   && (try? CachedFile(url)) == file
           }) {
            progress(selected.count, selected.count, "复用已校验的歌单副本")
            return PreparedPlaylist(files: cache.outputs.map { (URL(fileURLWithPath: $0.path), cache.base) },
                                    originals: selected.map(\.item), missing: missing)
        }
        let base = root.appendingPathComponent("work/playlist-imports/\(selection.id)/\(UUID().uuidString)")
        // Flat device layout: the Rockbox importer mirrors paths relative to
        // `base`, so staging the songs directly inside one folder named after
        // the playlist lands them on the device as Music/<playlist name>/
        // with no wrapper, session or per-track folders in between.
        let folder = base.appendingPathComponent(Self.deviceFolderName(selection))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inputCover = base.appendingPathComponent("source-cover")
        try coverData.write(to: inputCover, options: .withoutOverwriting)
        var files: [(url: URL, root: URL)] = []
        let numberWidth = selected.count > 99 ? 3 : 2
        for (index, track) in selected.enumerated() {
            progress(index, selected.count, "生成歌单副本：" + (track.tags["title"] ?? track.item.url.lastPathComponent))
            // Number by playlist position, not by the source album's own
            // track number (batch downloads are mostly singles, all "01.").
            let stem = Self.playlistFileStem(track.item.url, ordinal: index + 1, width: numberWidth)
            var destination = folder.appendingPathComponent(stem + "." + track.item.url.pathExtension)
            var collision = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent(stem + " (\(collision))." + track.item.url.pathExtension)
                collision += 1
            }
            try FileManager.default.copyItem(at: track.item.url, to: destination)
            // The cover belongs to this track only: keep it beside the song
            // under the song's own name instead of a shared cover.jpg.
            if let artwork = try? run(tool: "ffmpeg", arguments: ["-v", "error", "-i", track.item.url.path,
                "-map", "0:v:0", "-frames:v", "1", "-f", "image2pipe", "-vcodec", "png", "pipe:1"]),
               let source = CGImageSourceCreateWithData(artwork as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                   [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: coverMaxPixel,
                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
               let writer = CGImageDestinationCreateWithURL(destination.deletingPathExtension().appendingPathExtension("jpg") as CFURL,
                   UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
                guard CGImageDestinationFinalize(writer) else { throw PlaylistLibraryError.conversionFailed }
            }
            let tags = try metadata(destination)
            guard tags["album"] == track.tags["album"], tags["album_artist"] == track.tags["album_artist"],
                  tags["title"] == track.tags["title"], tags["artist"] == track.tags["artist"] else {
                throw PlaylistLibraryError.conversionFailed
            }
            files.append((destination, base))
        }
        let cache = Cache(selection: selection, sources: sources, outputs: try files.map { try CachedFile($0.url) },
                          base: base, cover: inputCover, missing: missing, appearanceVersion: appearanceVersion)
        try JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        return PreparedPlaylist(files: files, originals: selected.map(\.item), missing: missing)
    }

    private func metadata(_ url: URL) throws -> [String: String] {
        let data = try run(tool: "ffprobe", arguments: ["-v", "error", "-show_entries", "format_tags", "-of", "json", url.path])
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = object["format"] as? [String: Any] else { throw PlaylistLibraryError.conversionFailed }
        return format["tags"] as? [String: String] ?? [:]
    }

    @discardableResult
    private func run(tool: String, arguments: [String]) throws -> Data {
        guard let binary = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map({ $0 + tool })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw PlaylistLibraryError.missingTools }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = tool == "ffmpeg" ? ["-nostdin"] + arguments : arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        defer { timeout.cancel() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PlaylistLibraryError.conversionFailed }
        return data
    }
}
