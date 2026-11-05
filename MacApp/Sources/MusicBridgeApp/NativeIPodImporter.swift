import Foundation
import Darwin

enum NativeImportError: LocalizedError {
    case missingEngine, incompatibleEngine, invalidDevice, invalidPlan, libraryChanged, engineFailed, backupFailed
    var errorDescription: String? {
        switch self {
        case .missingEngine: return "尚未安装原生导入引擎。请按 README 安装 podkit 0.6.0 后重试；Rockbox 导入仍可使用。"
        case .incompatibleEngine: return "原生导入需要 podkit 0.6.0，当前版本尚未适配，已停止。"
        case .invalidDevice: return "原生音乐库不可用或设备已变化。请确认 iPod 已挂载、可写，并已由官方工具初始化。"
        case .invalidPlan: return "导入计划无法确认，或包含对已有歌曲的修改，已停止写入。首版原生导入只支持新增歌曲。"
        case .libraryChanged: return "设备音乐库或待导入文件已变化，请重新预览。"
        case .engineFailed: return "原生同步未完整成功。请保留连接并检查设备；数据库备份保存在 work/native-imports 中，勿立即重复导入。"
        case .backupFailed: return "原生数据库备份未通过，已停止写入。"
        }
    }
}

struct NativeImportPlan: Identifiable, Sendable {
    let id: UUID
    let device: IPodDevice
    let engine: URL
    let workspace: URL
    let sourceCount: Int
    let missing: Int
    let summary: NativePlanSummary
    let databaseFiles: [String: FileSignature]
    let stagedFiles: [String: FileSignature]
    var assessment: NativeAudioAssessment? = nil
    var playlist: PlaylistSelection? = nil
    var unmatchedSongs: [PlaylistSong] = []
    var backupURL: URL { workspace.appendingPathComponent("database-backup") }
}

struct NativePlanSummary: Equatable, Sendable {
    let additions: Int
    let existing: Int
    let conversions: Int
}

struct NativeImportResult: Sendable {
    let completed: Int
    let existing: Int
    let backup: URL?
    var playlistCount: Int? = nil
}

/// An external, version-pinned CLI boundary. Never changes global podkit config,
/// never passes --delete/--force-*/--check-artwork, and never runs on download completion.
struct NativeIPodImporter: Sendable {
    static let engineVersion = "0.6.0"
    let root: URL
    // Test seam only: the app always uses the real mount/UUID validation below.
    // No configuration or environment variable can enable this override.
    var mountValidator: (@Sendable (IPodDevice) throws -> Void)? = nil

    func engineURL() -> URL? {
        let paths = [root.appendingPathComponent("work/native-tools/podkit-0.6.0/podkit").path,
                     "/opt/homebrew/bin/podkit", "/usr/local/bin/podkit"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    func verifiedEngineURL() throws -> URL {
        guard let engine = engineURL() else { throw NativeImportError.missingEngine }
        let version = try run(engine, arguments: ["--version"], timeout: 15)
        guard version.status == 0,
              String(data: version.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.engineVersion else {
            throw NativeImportError.incompatibleEngine
        }
        return engine
    }

    static func configuration(source: URL) -> String {
        // JSON basic-string escaping is also valid for these TOML paths.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let quoted = String(data: try! encoder.encode(source.path), encoding: .utf8)!
        return """
        version = 1
        quality = "max"
        artwork = true
        skipUpgrades = true
        checkArtwork = false
        cleanArtists = false
        [music.bridge]
        path = \(quoted)

        """
    }

    static func arguments(config: URL, device: IPodDevice, dryRun: Bool) -> [String] {
        ["--config", config.path, "--device", device.rootURL.path, "--json", "--no-color", "--no-tips",
         "sync", "--type", "music", "--collection", "bridge", "--skip-upgrades"] + (dryRun ? ["--dry-run"] : [])
    }

    func prepare(files: [(url: URL, root: URL)], device: IPodDevice, missing: Int, playlist: PlaylistSelection? = nil,
                 progress: @Sendable (String) -> Void) throws -> NativeImportPlan {
        guard let engine = engineURL() else { throw NativeImportError.missingEngine }
        try validate(device)
        let version = try run(engine, arguments: ["--version"], timeout: 15)
        guard version.status == 0,
              String(data: version.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.engineVersion else {
            throw NativeImportError.incompatibleEngine
        }
        guard !files.isEmpty else { throw PlaylistLibraryError.noLocalTracks }
        var assessment = try NativeAudioPlanner().assess(files, device: device, progress: progress)
        let id = UUID()
        let workspace = root.appendingPathComponent("work/native-imports/\(id.uuidString)")
        let source = workspace.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (index, item) in assessment.ready.enumerated() {
            try Task.checkCancellation()
            let original = item.url
            guard try NativeAudioTools.signature(original) == item.signature else { throw NativeAudioError.changed }
            // Isolated local copies ensure the engine cannot modify the original downloads.
            let folder = source.appendingPathComponent(String(index))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(item.disposition == .sameSpecALAC
                ? original.deletingPathExtension().lastPathComponent + ".m4a" : original.lastPathComponent)
            do {
            let before = try signature(original)
            if item.disposition == .sameSpecALAC, let spec = item.spec {
                _ = try NativeAudioTools.convert(item, to: destination,
                    target: NativeAudioSpec(codec: "alac", bits: spec.bits, rate: spec.rate, channels: spec.channels))
            } else {
                try NativeAudioTools.decodeCheck(original)
                try FileManager.default.copyItem(at: original, to: destination)
            }
            guard try signature(original) == before else {
                throw NativeImportError.libraryChanged
            }
            progress("准备同规格导入副本 \(index + 1) / \(assessment.ready.count)")
            } catch {
                // Remove only this task's failed local copy, so the CLI cannot scan it.
                try FileManager.default.removeItem(at: folder)
                if let position = assessment.items.firstIndex(where: { $0.id == item.id }) {
                    assessment.items[position] = NativeAudioItem(url: item.url, sourceRoot: item.sourceRoot, signature: item.signature,
                        spec: item.spec, disposition: .unresolved, reason: error.localizedDescription, target: nil)
                }
            }
        }
        let config = workspace.appendingPathComponent("config.toml")
        try Self.configuration(source: source).write(to: config, atomically: true, encoding: .utf8)
        let stamps = try databaseSnapshot(device)
        progress("正在读取原生数据库并生成导入预览")
        var summary = NativePlanSummary(additions: 0, existing: 0, conversions: 0)
        if !assessment.ready.isEmpty {
            let preview = try run(engine, arguments: Self.arguments(config: config, device: device, dryRun: true), timeout: 1800, device: device)
            guard preview.status == 0 else { throw NativeImportError.invalidPlan }
            summary = try Self.parsePlan(preview.data, sourceCount: assessment.ready.count)
        }
        try validate(device)
        guard try databaseSnapshot(device) == stamps else { throw NativeImportError.libraryChanged }
        return NativeImportPlan(id: id, device: device, engine: engine, workspace: workspace,
                                sourceCount: assessment.ready.count, missing: missing, summary: summary,
                                databaseFiles: stamps, stagedFiles: try snapshot(source), assessment: assessment, playlist: playlist)
    }

    func execute(_ plan: NativeImportPlan, progress: @Sendable (String) -> Void) throws -> NativeImportResult {
        try validate(plan.device)
        guard try databaseSnapshot(plan.device) == plan.databaseFiles,
              try snapshot(plan.workspace.appendingPathComponent("music")) == plan.stagedFiles else {
            throw NativeImportError.libraryChanged
        }
        if plan.summary.additions == 0 {
            return try finishPlaylist(plan, completed: 0, backedUp: false, progress: progress)
        }
        let version = try run(plan.engine, arguments: ["--version"], timeout: 15)
        guard version.status == 0,
              String(data: version.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.engineVersion else {
            throw NativeImportError.incompatibleEngine
        }
        let config = plan.workspace.appendingPathComponent("config.toml")
        // Recreate our isolated config rather than trusting a file edited after preview.
        try Self.configuration(source: plan.workspace.appendingPathComponent("music"))
            .write(to: config, atomically: true, encoding: .utf8)
        progress("正在重新确认导入计划")
        let preview = try run(plan.engine, arguments: Self.arguments(config: config, device: plan.device, dryRun: true), timeout: 1800, device: plan.device)
        guard preview.status == 0,
              try Self.parsePlan(preview.data, sourceCount: plan.sourceCount) == plan.summary else {
            throw NativeImportError.libraryChanged
        }
        let beforeCount = try readTrackCount(plan)
        try validate(plan.device)
        guard try databaseSnapshot(plan.device) == plan.databaseFiles else { throw NativeImportError.libraryChanged }
        progress("正在备份原生数据库与封面索引")
        try backup(plan)
        try validate(plan.device)
        guard try databaseSnapshot(plan.device) == plan.databaseFiles else { throw NativeImportError.libraryChanged }
        progress("正在复制兼容歌曲与封面、写入原生数据库，请保持连接")
        let output = try run(plan.engine, arguments: Self.arguments(config: config, device: plan.device, dryRun: false), timeout: 7200, device: plan.device)
        try validate(plan.device)
        let completed = try Self.parseResult(output.data, exitStatus: output.status)
        guard completed == plan.summary.additions else { throw NativeImportError.engineFailed }
        progress("正在重新读取原生音乐库")
        guard try readTrackCount(plan) == beforeCount + completed else { throw NativeImportError.engineFailed }
        return try finishPlaylist(plan, completed: completed, backedUp: true, progress: progress)
    }

    private func finishPlaylist(_ plan: NativeImportPlan, completed: Int, backedUp: Bool,
                                progress: @Sendable (String) -> Void) throws -> NativeImportResult {
        guard let selection = plan.playlist else {
            return NativeImportResult(completed: completed, existing: plan.summary.existing, backup: backedUp ? plan.backupURL : nil)
        }
        var library = NativeLibraryService(root: root)
        library.mountValidator = mountValidator
        progress("正在匹配原生播放列表与设备文件")
        let preview = try library.playlist(selection, device: plan.device, save: false)
        var didBackup = backedUp
        if preview.changed {
            try validate(plan.device)
            if !didBackup { try backup(plan); didBackup = true }
            progress("正在更新同名播放列表并保留源歌单顺序")
            let saved = try library.playlist(selection, device: plan.device, save: true)
            guard saved.count == preview.count else { throw NativeImportError.engineFailed }
        }
        progress("已校验 \(preview.files.count) 个设备文件与播放列表；实机播放待确认")
        try validate(plan.device)
        return NativeImportResult(completed: completed, existing: plan.summary.existing,
                                  backup: didBackup ? plan.backupURL : nil, playlistCount: preview.count)
    }

    private func readTrackCount(_ plan: NativeImportPlan) throws -> Int {
        let output = try run(plan.engine, arguments: ["--config", plan.workspace.appendingPathComponent("config.toml").path,
            "--device", plan.device.rootURL.path, "--json", "--no-color", "--no-tips", "device", "music", "--tracks"],
            timeout: 120, device: plan.device)
        guard output.status == 0,
              let tracks = try JSONSerialization.jsonObject(with: output.data) as? [[String: Any]] else {
            throw NativeImportError.engineFailed
        }
        return tracks.count
    }

    static func parsePlan(_ data: Data, sourceCount: Int) throws -> NativePlanSummary {
        let documents = try jsonDocuments(data)
        guard documents.count == 1, let doc = documents.first,
              doc["success"] as? Bool == true, doc["dryRun"] as? Bool == true,
              let plan = doc["plan"] as? [String: Any],
              let add = plan["tracksToAdd"] as? Int, add >= 0,
              let existing = plan["tracksExisting"] as? Int, existing >= 0,
              let transcode = plan["tracksToTranscode"] as? Int, transcode >= 0,
              let copy = plan["tracksToCopy"] as? Int, copy >= 0,
              add + existing == sourceCount, transcode == 0, copy == add,
              ["tracksToRemove", "tracksToUpdate", "tracksToUpgrade"].allSatisfy({ plan[$0] as? Int == 0 }),
              (doc["scanWarnings"] as? [Any] ?? []).isEmpty,
              (doc["errors"] as? [Any] ?? []).isEmpty,
              let operations = doc["operations"] as? [[String: Any]], operations.count == add,
              operations.allSatisfy({ $0["type"] as? String == "copy" }) else {
            throw NativeImportError.invalidPlan
        }
        return NativePlanSummary(additions: add, existing: existing, conversions: transcode)
    }

    static func parseResult(_ data: Data, exitStatus: Int32) throws -> Int {
        let documents = try jsonDocuments(data)
        guard exitStatus == 0, !documents.isEmpty,
              documents.allSatisfy({ $0["success"] as? Bool == true && $0["dryRun"] as? Bool == false
                  && ($0["errors"] as? [Any] ?? []).isEmpty
                  && ($0["executionWarnings"] as? [Any] ?? []).isEmpty }),
              let result = documents.last?["result"] as? [String: Any],
              result["failed"] as? Int == 0, let completed = result["completed"] as? Int, completed >= 0 else {
            throw NativeImportError.engineFailed
        }
        return completed
    }

    /// podkit 0.6 emits consecutive pretty-printed JSON objects, not one JSON array.
    private static func jsonDocuments(_ data: Data) throws -> [[String: Any]] {
        var documents: [[String: Any]] = []
        var depth = 0, start = 0
        var quoted = false, escaped = false
        let bytes = Array(data)
        for (index, byte) in bytes.enumerated() {
            if depth == 0 {
                if [9, 10, 13, 32].contains(byte) { continue }
                guard byte == 123 else { throw NativeImportError.invalidPlan }
                start = index
            }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 { depth += 1 }
            else if byte == 125 {
                depth -= 1
                if depth == 0 {
                    guard let doc = try JSONSerialization.jsonObject(with: Data(bytes[start...index])) as? [String: Any] else {
                        throw NativeImportError.invalidPlan
                    }
                    documents.append(doc)
                }
            }
        }
        guard depth == 0, !quoted, !documents.isEmpty else { throw NativeImportError.invalidPlan }
        return documents
    }

    private func validateMount(_ device: IPodDevice) throws {
        if let mountValidator { try mountValidator(device); return }
        // Use a fresh URL so cached URL resource values cannot mask a remount.
        let root = URL(fileURLWithPath: device.rootURL.path)
        guard device.hasNativeDatabase, device.canImport, let identity = device.volumeIdentifier,
              let values = try? root.resourceValues(forKeys: [.isVolumeKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey]),
              values.isVolume == true, values.volumeIsReadOnly == false, values.volumeUUIDString == identity else {
            throw NativeImportError.invalidDevice
        }
    }

    private func validate(_ device: IPodDevice) throws {
        try validateMount(device)
        var current = IPodKnowledge.read(at: device.rootURL)
        current.userConfirmedProfileID = device.identity.userConfirmedProfileID
        guard device.identity.permitsNativeImport, current == device.identity else {
            throw NativeAudioError.unknownModel
        }
        let db = device.rootURL.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        guard db.resolvingSymlinksInPath().path == db.path,
              FileManager.default.isWritableFile(atPath: db.path) else { throw NativeImportError.invalidDevice }
        let handle = try FileHandle(forReadingFrom: db)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("mhbd".utf8) else { throw NativeImportError.invalidDevice }
    }

    private func signature(_ file: URL) throws -> FileSignature {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let date = values.contentModificationDate else { throw NativeImportError.backupFailed }
        return FileSignature(size: UInt64(size), modificationDate: date)
    }

    private func snapshot(_ directory: URL) throws -> [String: FileSignature] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [:] }
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw NativeImportError.backupFailed }
        var result: [String: FileSignature] = [:]
        // contentsOfDirectory throws on unreadable subdirectories instead of silently
        // accepting a partial backup from FileManager's recursive enumerator.
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) {
            guard file.resolvingSymlinksInPath().path == file.path else { throw NativeImportError.backupFailed }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isRegularFile == true {
                result[file.lastPathComponent] = try signature(file)
            } else if values.isDirectory == true {
                for (path, stamp) in try snapshot(file) { result[file.lastPathComponent + "/" + path] = stamp }
            } else {
                throw NativeImportError.backupFailed
            }
        }
        return result
    }

    private func databaseSnapshot(_ device: IPodDevice) throws -> [String: FileSignature] {
        var result: [String: FileSignature] = [:]
        for name in ["iTunes", "Artwork", "Device"] {
            for (path, stamp) in try snapshot(device.rootURL.appendingPathComponent("iPod_Control/" + name)) {
                result[name + "/" + path] = stamp
            }
        }
        guard result["iTunes/iTunesDB"] != nil else { throw NativeImportError.invalidDevice }
        return result
    }

    private func backup(_ plan: NativeImportPlan) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: plan.backupURL.path) else { throw NativeImportError.backupFailed }
        for (path, stamp) in plan.databaseFiles {
            try validate(plan.device)
            let original = plan.device.rootURL.appendingPathComponent("iPod_Control/" + path)
            let destination = plan.backupURL.appendingPathComponent(path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: original, to: destination)
            guard try signature(destination).size == stamp.size, try signature(original) == stamp else {
                throw NativeImportError.backupFailed
            }
        }
    }

    private func run(_ executable: URL, arguments: [String], timeout: TimeInterval,
                     device: IPodDevice? = nil) throws -> (status: Int32, data: Data) {
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        // Ignore the user's podkit env/config and close stdin; never answer prompts automatically.
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PODKIT_") }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("musicbridge-native-\(UUID()).json")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            // The database can legitimately be in the middle of a write here.
            // Only monitor the mount identity until the process finishes.
            let deviceChanged = device.map { (try? validateMount($0)) == nil } ?? false
            if Task.isCancelled || Date() > deadline || deviceChanged {
                process.terminate()
                // Give the engine time to save its interrupted database, then bound the wait.
                let grace = Date().addingTimeInterval(10)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                throw NativeImportError.engineFailed
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        guard try signature(output).size < 32 * 1024 * 1024 else { throw NativeImportError.invalidPlan }
        return (process.terminationStatus, try Data(contentsOf: output))
    }
}
