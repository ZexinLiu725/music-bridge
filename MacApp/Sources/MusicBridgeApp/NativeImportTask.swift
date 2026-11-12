import Foundation

struct NativeTaskEntry: Codable, Identifiable, Sendable {
    var id: String { original.path }
    let original: URL
    let sourceSpec: String
    let targetSpec: String
    var status: String
    var detail: String
    var converted: URL? = nil
}

struct NativeImportTask: Codable, Identifiable, Sendable {
    let id: UUID
    let deviceUUID: String?
    let deviceRoot: URL
    let playlistName: String?
    var stage = "准备首轮导入"
    var total: Int
    var compatible: Int
    var imported = 0
    var existing = 0
    var pending: Int
    var blocked: Int
    var unmatched: Int
    var conversionFailures = 0
    var playlistCount: Int? = nil
    var entries: [NativeTaskEntry]
    var unmatchedSongs: [PlaylistSong] = []
    var backups: [URL] = []
    var writeVerified = false
    var ejected = false
    var playback = "待实机确认"
    var playbackIssue = ""

    init(plan: NativeImportPlan) {
        id = plan.id; deviceUUID = plan.device.volumeIdentifier; deviceRoot = plan.device.rootURL
        playlistName = plan.playlist?.name
        let assessment = plan.assessment
        total = plan.playlist?.sourceTrackCount ?? (assessment?.items.count ?? plan.sourceCount) + plan.missing
        compatible = assessment?.ready.count ?? plan.sourceCount
        pending = assessment?.pending.count ?? 0; blocked = assessment?.blocked.count ?? 0; unmatched = plan.missing
        unmatchedSongs = plan.unmatchedSongs
        entries = (assessment?.items ?? []).map { item in
            let status: String
            switch item.disposition {
            case .direct: status = "首轮原样导入"
            case .sameSpecALAC: status = "同规格转 ALAC"
            case .deferred: status = "待选择转换"
            case .unresolved: status = "无法确认"
            }
            return NativeTaskEntry(original: item.url, sourceSpec: item.spec?.description ?? "规格未知",
                                   targetSpec: item.target?.description ?? item.spec?.description ?? "未确定",
                                   status: status, detail: item.reason)
        }
    }

    static func load(root: URL) -> Self? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("work/native-imports/latest-task.json")) else { return nil }
        guard var task = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        if !task.writeVerified, !task.stage.contains("取消") {
            task.stage = "上次任务未确认完成；请重新预览。原文件与已保存的备份保留。"
        }
        return task
    }

    func save(root: URL) throws {
        let file = root.appendingPathComponent("work/native-imports/latest-task.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}

struct NativeInitializationRequest: Identifiable {
    let id = UUID()
    let device: IPodDevice
}

final class NativeTaskWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MusicBridge.native-task-writer", qos: .utility)
    func enqueue(_ task: NativeImportTask, root: URL, error: @escaping @Sendable (String) -> Void) {
        queue.async {
            do { try task.save(root: root) }
            catch let failure { error(failure.localizedDescription) }
        }
    }
    func flush() { queue.sync {} }
}
