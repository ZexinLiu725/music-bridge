import Foundation
import Darwin

struct NativeLibraryFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct NativePlaylistResult: Decodable, Sendable {
    struct File: Decodable, Sendable { let relative: String; let size: UInt64; let artwork: Bool }
    let changed: Bool
    let count: Int
    let files: [File]
    let titles: [String]
}

/// Only the pinned engine's bundled native module is used, with its bundled Bun runtime.
/// No system Node dependency, user config, force-reset, or fallback model.
struct NativeLibraryService: Sendable {
    let root: URL
    var mountValidator: (@Sendable (IPodDevice) throws -> Void)? = nil
    var identifierProvider: (@Sendable (IPodDevice) -> String?)? = nil

    func validateMount(_ device: IPodDevice) throws {
        if let mountValidator { try mountValidator(device); return }
        let url = URL(fileURLWithPath: device.rootURL.path)
        let values = try url.resourceValues(forKeys: [.isVolumeKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey])
        guard device.canImport, values.isVolume == true, values.volumeIsReadOnly == false,
              let uuid = device.volumeIdentifier, values.volumeUUIDString == uuid,
              url.resolvingSymlinksInPath().path == url.path else { throw NativeImportError.invalidDevice }
    }

    func initialize(_ device: IPodDevice, profileID: String, progress: @Sendable (String) -> Void) throws -> URL {
        try validateMount(device)
        let identity = IPodKnowledge.read(at: device.rootURL)
        guard !identity.conflict, IPodKnowledge.profiles.contains(where: { $0.id == profileID && $0.nativeWriterSupported }),
              identity.profileID == profileID || identity.allowsManualProfile(profileID) else { throw NativeAudioError.unknownModel }
        let control = device.rootURL.appendingPathComponent("iPod_Control")
        func checkAbsent() throws {
            try validateMount(device)
            for name in ["iTunesDB", "iTunesCDB"] {
                guard !FileManager.default.fileExists(atPath: control.appendingPathComponent("iTunes/" + name).path) else {
                    throw NativeLibraryFailure(message: "原生曲库已经存在，未覆盖。请刷新设备后直接导入。")
                }
            }
        }
        try checkAbsent()
        let before = try snapshot(control)
        guard !before.keys.contains(where: { $0.hasPrefix("Music/") && !$0.split(separator: "/").last!.hasPrefix(".") }),
              before.values.reduce(UInt64(0), { $0 + $1.size }) < 64 * 1024 * 1024 else {
            throw NativeLibraryFailure(message: "检测到没有数据库的原生媒体文件，已停止初始化。请先恢复已有曲库，避免遗失歌曲归属。")
        }
        guard let identifier = identifierProvider?(device) ?? IPodKnowledge.hardwareIdentifier(at: device.rootURL),
              identifier.range(of: "^[A-Fa-f0-9]{16}$", options: .regularExpression) != nil else {
            throw NativeLibraryFailure(message: "未能从当前 iPod 读取真实硬件标识。请在苹果原生系统下重新连接，再初始化曲库。")
        }
        let workspace = root.appendingPathComponent("work/native-initializations/\(UUID())")
        let backup = workspace.appendingPathComponent("backup")
        progress("正在备份现有设备信息；保留 Rockbox 与歌曲")
        try copySnapshot(before, from: control, to: backup)
        guard try snapshot(control) == before, IPodKnowledge.read(at: device.rootURL) == identity else { throw NativeImportError.libraryChanged }
        try checkAbsent()
        progress("正在按已确认的机型创建原生曲库")
        do {
            _ = try invoke(["action":"initialize", "mount":device.rootURL.path, "profile":profileID,
                            "detectedProfile":identity.profileID ?? "", "hardwareIdentifier":identifier,
                            "name":device.name], device: device)
            try validateMount(device)
            let db = control.appendingPathComponent("iTunes/iTunesDB")
            let handle = try FileHandle(forReadingFrom: db)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 4) == Data("mhbd".utf8) else { throw NativeImportError.invalidDevice }
            progress("空曲库已回读确认；设备信息备份已保存")
            return backup
        } catch {
            throw NativeLibraryFailure(message: "初始化未确认完成：\(error.localizedDescription) 备份位置：\(backup.path)")
        }
    }

    func playlist(_ selection: PlaylistSelection, device: IPodDevice, save: Bool) throws -> NativePlaylistResult {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection))
        let data = try invoke(["action":save ? "playlist-save" : "playlist-preview", "mount":device.rootURL.path,
                               "playlist":object], device: device)
        return try JSONDecoder().decode(NativePlaylistResult.self, from: data)
    }

    func snapshot(_ directory: URL) throws -> [String: FileSignature] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw NativeImportError.backupFailed }
        var result: [String: FileSignature] = [:]
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]) {
            let v = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard file.resolvingSymlinksInPath().path == file.path else { throw NativeImportError.backupFailed }
            if v.isDirectory == true {
                for (key, value) in try snapshot(file) { result[file.lastPathComponent + "/" + key] = value }
            } else if v.isRegularFile == true, let size = v.fileSize, let date = v.contentModificationDate {
                result[file.lastPathComponent] = FileSignature(size: UInt64(size), modificationDate: date)
            } else { throw NativeImportError.backupFailed }
        }
        return result
    }

    private func copySnapshot(_ files: [String: FileSignature], from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (path, signature) in files {
            let original = source.appendingPathComponent(path), copy = destination.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Copy data without FAT metadata flags that can prevent a readable backup on APFS.
            let data = try Data(contentsOf: original)
            guard UInt64(data.count) == signature.size else { throw NativeImportError.backupFailed }
            try data.write(to: copy, options: .withoutOverwriting)
            guard try Data(contentsOf: copy) == data else { throw NativeImportError.backupFailed }
        }
    }

    private func invoke(_ input: [String: Any], device: IPodDevice) throws -> Data {
        try validateMount(device)
        let engine = try NativeIPodImporter(root: root).verifiedEngineURL()
        let helper = root.appendingPathComponent("script/native_library.cjs")
        guard FileManager.default.fileExists(atPath: helper.path) else { throw NativeImportError.missingEngine }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MusicBridgeLibrary-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }
        let request = base.appendingPathComponent("request"), output = base.appendingPathComponent("result")
        try JSONSerialization.data(withJSONObject: input).write(to: request)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let stdin = try FileHandle(forReadingFrom: request), stdout = try FileHandle(forWritingTo: output)
        defer { try? stdin.close(); try? stdout.close() }
        let process = Process(); process.executableURL = engine; process.arguments = [helper.path]
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PODKIT_") && !$0.key.hasPrefix("BUN_") }
        env["BUN_BE_BUN"] = "1"
        process.environment = env; process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline || (try? validateMount(device)) == nil {
                process.terminate()
                let grace = Date().addingTimeInterval(10)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.1) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); throw NativeImportError.engineFailed
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit()
        try validateMount(device)
        guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 8 * 1024 * 1024 else { throw NativeImportError.invalidPlan }
        let data = try Data(contentsOf: output)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NativeImportError.engineFailed }
        guard process.terminationStatus == 0, result["success"] as? Bool == true else {
            throw NativeLibraryFailure(message: result["error"] as? String ?? "原生曲库操作未完成，请保留连接检查。")
        }
        return data
    }
}
