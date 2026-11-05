import Foundation

struct GoMusicClient {
    func exportPlaylist(url: String) async throws -> PlaylistExport {
        // Retain ordered membership, name and artwork for device import.
        let playlist = try await PlaylistSelection.netease(url: url)
        return PlaylistExport(text: playlist.tracks.map { "\($0.title) - \($0.artist)" }.joined(separator: "\n"),
                              count: playlist.tracks.count, playlist: playlist)
    }
}
