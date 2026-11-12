import Foundation

enum DownloadJobEntryState: String, Codable {
    case pending, downloading, downloaded, skipped, failed, timedOut
}

/// The closest catalog candidate for a song the matcher would not accept
/// automatically, kept with the skip so the user can review and override.
struct DownloadJobReview: Codable, Equatable {
    var title: String
    var artist: String
    var album: String? = nil
    var url: String
    var durationMs: Int? = nil
    var score: Double
    var reason: String
}

struct DownloadJobEntry: Codable, Equatable {
    var title: String
    var artist: String
    var album: String? = nil
    var url: String? = nil
    var state: DownloadJobEntryState
    var attempts: Int = 0
    var detail: String? = nil
    var review: DownloadJobReview? = nil
    /// Where the file actually came from: nil is the normal Apple route,
    /// "netease" marks a fallback download from the source platform.
    var source: String? = nil
    /// The song's ID on the source platform, kept so the fallback source
    /// can fetch this exact track later without any fuzzy matching.
    var neteaseID: String? = nil
    /// The track's ID on QQ Music / Kugou for entries from those platforms.
    var platformID: String? = nil
}

struct DownloadJobReport: Codable, Equatable {
    var generatedAt: Date
    var downloaded: [String]
    var skipped: [String]
    var failed: [String]
    var timedOut: [String]
    var warnings: [String] = []
    var fallbackDownloads: [String] = []
}

struct DownloadJob: Codable, Equatable {
    var id: String
    var name: String
    var sourceURL: String
    var createdAt: Date
    var updatedAt: Date
    var finishedAt: Date? = nil
    var entries: [DownloadJobEntry]
    var report: DownloadJobReport? = nil
}

/// Persists one JSON ledger per playlist under work/jobs/, following the
/// same convention as PlaylistLibrary's work/playlists/selected.json. The
/// ledger is what makes a download resumable: every song's state is saved
/// as it changes, so an app restart or a stopped run loses nothing, and an
/// unfinished job can be picked up exactly where it stopped.
struct DownloadJobStore {
    let root: URL

    private func file(for id: String) -> URL {
        let safe = id.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "_")
        return root.appendingPathComponent("work/jobs/\(safe).json")
    }

    func save(_ job: DownloadJob) throws {
        let file = file(for: job.id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(job).write(to: file, options: .atomic)
    }

    func load(id: String) -> DownloadJob? {
        guard let data = try? Data(contentsOf: file(for: id)) else { return nil }
        return try? JSONDecoder().decode(DownloadJob.self, from: data)
    }
}
