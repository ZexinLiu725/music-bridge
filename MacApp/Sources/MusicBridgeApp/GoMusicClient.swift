import Foundation

struct GoMusicClient {
    func exportPlaylist(url: String) async throws -> PlaylistExport {
        // Retain ordered membership, name and artwork for device import.
        // Recognition covers NetEase, QQ Music and Kugou playlists; the
        // parsers all produce the same PlaylistSelection, so the rest of
        // the pipeline never cares which platform a link came from.
        let playlist: PlaylistSelection
        switch PlaylistSource.identify(url) {
        case .qq:
            playlist = try await PlaylistSelection.qq(url: url)
        case .kugou:
            playlist = try await PlaylistSelection.kugou(url: url)
        default:
            playlist = try await PlaylistSelection.netease(url: url)
        }
        return PlaylistExport(text: playlist.tracks.map { "\($0.title) - \($0.artist)" }.joined(separator: "\n"),
                              count: playlist.tracks.count, playlist: playlist)
    }
}
