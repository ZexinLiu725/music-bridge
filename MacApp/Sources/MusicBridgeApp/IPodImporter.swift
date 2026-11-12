import AppKit

struct FileSignature: Sendable, Equatable {
    let size: UInt64
    let modificationDate: Date
}

enum DeviceWriteState: String, Sendable {
    case writable = "可写"
    case readOnly = "只读"
    case unknown = "待确认"
}

enum IPodImportMode: String, CaseIterable, Identifiable {
    case automatic = "自动", native = "原生", rockbox = "Rockbox"
    var id: String { rawValue }
}

struct IPodDevice: Sendable, Equatable {
    let name: String
    let rootURL: URL
    let musicURL: URL
    let writeState: DeviceWriteState
    let isRockbox: Bool
    var volumeIdentifier: String? = nil
    var hasNativeDatabase: Bool = false
    var identity: IPodIdentity = .unknown
    var hasCompressedNativeDatabase = false
    var nativeDatabaseUnreadable = false
    var formatDescription: String? = nil
    var availableBytes: Int64? = nil
    var totalBytes: Int64? = nil
    var selectionKey: String { volumeIdentifier ?? rootURL.path }
    func matchesImportTarget(_ other: Self) -> Bool {
        var lhs = self, rhs = other
        lhs.availableBytes = nil; lhs.totalBytes = nil; lhs.formatDescription = nil
        rhs.availableBytes = nil; rhs.totalBytes = nil; rhs.formatDescription = nil
        return lhs == rhs
    }

    var canImport: Bool { writeState == .writable }
    var systemDescription: String {
        if nativeDatabaseUnreadable { return "发现原生数据库文件 · 读取未通过" }
        if hasCompressedNativeDatabase && !hasNativeDatabase { return "发现压缩原生曲库 · 当前写入未适配" }
        if isRockbox && hasNativeDatabase { return "检测到 Rockbox 与原生音乐库" }
        return isRockbox ? "检测到 Rockbox · 尚未建立原生曲库" : hasNativeDatabase ? "检测到原生音乐库" : "尚未建立原生曲库"
    }
    func resolvedMode(_ mode: IPodImportMode) -> IPodImportMode? {
        switch mode {
        case .automatic: return isRockbox ? .rockbox : hasNativeDatabase ? .native : nil
        case .rockbox: return isRockbox ? .rockbox : nil
        case .native: return hasNativeDatabase ? .native : nil
        }
    }
}

struct MediaCheckResult: Sendable {
    let playable: Bool
    let bitrate: Int?
    let hasEmbeddedCover: Bool
    let codec: String?
    var container: String? = nil
    var durationSeconds: Double? = nil
    var sampleRate: Int? = nil
}

struct IPodImportReport: Sendable {
    let deviceName: String
    let imported: Int
    let alreadyPresent: Int
    let skippedUnplayable: Int
    let failedFiles: Int
    let processedFiles: Int
    let missingSourceCovers: Int
    let missingDestinationCovers: Int
    let missingBitrates: Int
    let sourceFiles: Int
    let warningCount: Int
    let messages: [String]
    let libraryInstruction: String?
    let interrupted: Bool
}

struct IPodImportProgress: Sendable {
    enum Stage: Sendable { case copying, covers, verifying, library }
    let stage: Stage
    let total: Int
    let processed: Int
    let imported: Int
    let existing: Int
    let filename: String
    let fraction: Double
}

struct RockboxPreviewItem: Sendable, Identifiable {
    var id: String { url.path }
    let url: URL
    let root: URL
    let signature: FileSignature?
    let spec: NativeAudioSpec?
    let status: String
    let canCopy: Bool
    let destinationSize: UInt64?
}

struct RockboxImportPreview: Sendable, Identifiable {
    let id = UUID()
    let device: IPodDevice
    let playlistName: String?
    let playlistID: String?
    let missing: Int
    let items: [RockboxPreviewItem]
    let bytesNeeded: UInt64
    var ready: [RockboxPreviewItem] { items.filter(\.canCopy) }
}

/// Finds a mounted Rockbox/iPod volume, imports only files changed by the
/// current download, and verifies the media both before and after copying.
struct IPodImporter: Sendable {
    private let audioExtensions: Set<String> = ["m4a", "mp4", "mp3", "flac", "aac", "ogg", "opus", "wav"]

    func preview(_ files: [(url: URL, root: URL)], device: IPodDevice, playlistName: String?, playlistID: String?, missing: Int) throws -> RockboxImportPreview {
        try validateFilesystem(on: device)
        var items: [RockboxPreviewItem] = []
        var bytes: UInt64 = 0
        for item in files {
            try Task.checkCancellation()
            let stamp = try? NativeAudioTools.signature(item.url)
            let spec = try? NativeAudioTools.probe(item.url)
            let media = inspect(item.url)
            let destination = safeDestination(for: item.url, sourceRoot: item.root, device: device)
            let existing = destination.flatMap { signature(of: $0)?.size }
            let reason: String
            var ready = false
            if stamp == nil || destination == nil { reason = "文件或目标路径无法确认" }
            else if let destination, let volume = canonicalURL(device.rootURL),
                    (String(destination.path.dropFirst(volume.path.count)).utf8.count >= 260 || destination.path.contains("\n") || destination.path.contains("\r")) {
                reason = "目标路径过长或包含换行，无法安全写入歌单"
            }
            else if let spec, media.playable {
                if let issue = Self.rockboxFormatIssue(extension: item.url.pathExtension, codec: spec.codec, container: media.container) { reason = issue }
                else if let existing {
                    if existing == stamp!.size, let destination, (try? Self.sameContents(item.url, destination)) == true {
                        ready = true
                        reason = "已有文件内容一致，将加入歌单"
                    } else { reason = "同名内容不同或无法核对：保留设备文件" }
                } else {
                    ready = true
                    bytes = bytes.addingReportingOverflow(stamp!.size).overflow ? UInt64.max : bytes + stamp!.size
                    reason = "原样复制；设备播放尚未验证"
                }
            } else { reason = "无法识别音频规格或缺少 ffprobe" }
            items.append(.init(url: item.url, root: item.root, signature: stamp, spec: spec, status: reason, canCopy: ready, destinationSize: existing))
        }
        return .init(device: device, playlistName: playlistName, playlistID: playlistID, missing: missing, items: items, bytesNeeded: bytes)
    }

    func validatePreview(_ preview: RockboxImportPreview) throws {
        try validateFilesystem(on: preview.device)
        for item in preview.ready {
            guard let original = item.signature, (try? NativeAudioTools.signature(item.url)) == original,
                  let destination = safeDestination(for: item.url, sourceRoot: item.root, device: preview.device),
                  signature(of: destination)?.size == item.destinationSize else { throw NativeAudioError.changed }
        }
        if let capacity = (try? preview.device.rootURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,
           capacity >= 0, preview.bytesNeeded > UInt64(capacity) { throw RockboxPreviewError.insufficientSpace }
    }

    static func sameContents(_ left: URL, _ right: URL) throws -> Bool {
        let a = try FileHandle(forReadingFrom: left), b = try FileHandle(forReadingFrom: right)
        defer { try? a.close(); try? b.close() }
        while true {
            try Task.checkCancellation()
            let x = try a.read(upToCount: 256 * 1024) ?? Data()
            let y = try b.read(upToCount: 256 * 1024) ?? Data()
            if x != y { return false }
            if x.isEmpty { return true }
        }
    }

    func mountedDevices() -> [IPodDevice] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey, .volumeIsRemovableKey, .volumeIsReadOnlyKey],
            options: [.skipHiddenVolumes]
        ) ?? []

        return volumes.compactMap { detectDevice(at: $0) }
    }

    /// Detect available libraries, not the firmware currently running on a dual-boot iPod.
    func detectDevice(at rootURL: URL) -> IPodDevice? {
            let rockbox = rootURL.appendingPathComponent(".rockbox", isDirectory: true)
            let iPodControl = rootURL.appendingPathComponent("iPod_Control", isDirectory: true)
            let musicURL = rootURL.appendingPathComponent("Music", isDirectory: true)
            let database = iPodControl.appendingPathComponent("iTunes/iTunesDB")
            let databaseExists = FileManager.default.fileExists(atPath: database.path)
            let compressed = FileManager.default.fileExists(atPath: iPodControl.appendingPathComponent("iTunes/iTunesCDB").path)
            var native = false
            if let handle = try? FileHandle(forReadingFrom: database) {
                native = (try? handle.read(upToCount: 4)) == Data("mhbd".utf8)
                try? handle.close()
            }
            let identity = IPodKnowledge.read(at: rootURL)
            let ipodRockbox = isDirectory(rockbox) && (identity.rockboxTarget != nil || identity.usbIPodConfirmed)
            guard ipodRockbox || native || compressed || databaseExists || identity.usbIPodConfirmed || identity.profileID != nil else { return nil }
            let values = try? rootURL.resourceValues(forKeys: [.volumeNameKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey,
                .volumeLocalizedFormatDescriptionKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey])
            let writeTarget = isDirectory(musicURL) ? musicURL : rootURL
            let access: DeviceWriteState
            if values?.volumeIsReadOnly == true {
                access = .readOnly
            } else if values?.volumeIsReadOnly == false {
                access = FileManager.default.isWritableFile(atPath: writeTarget.path) ? .writable : .readOnly
            } else {
                access = .unknown
            }
            let name = values?.volumeName
                ?? rootURL.lastPathComponent
            return IPodDevice(name: name, rootURL: rootURL, musicURL: musicURL,
                              writeState: access, isRockbox: ipodRockbox || (isDirectory(rockbox) && native), volumeIdentifier: values?.volumeUUIDString,
                              hasNativeDatabase: native, identity: identity, hasCompressedNativeDatabase: compressed,
                              nativeDatabaseUnreadable: databaseExists && !native, formatDescription: values?.volumeLocalizedFormatDescription,
                              availableBytes: values?.volumeAvailableCapacity.map(Int64.init), totalBytes: values?.volumeTotalCapacity.map(Int64.init))
    }

    func sourceRoots(in workingDirectory: URL) -> [URL] {
        var roots: [URL] = []
        let configURL = workingDirectory.appendingPathComponent("config.yaml")
        if let config = try? String(contentsOf: configURL, encoding: .utf8) {
            for key in ["alac-save-folder", "atmos-save-folder", "aac-save-folder", "mv-save-folder"] {
                if let value = yamlValue(config, key: key), !value.isEmpty {
                    let root = URL(fileURLWithPath: value, relativeTo: workingDirectory).standardizedFileURL
                    if isDirectory(root) { roots.append(root) }
                }
            }
        }

        if let entries = try? FileManager.default.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            roots.append(contentsOf: entries.filter {
                $0.lastPathComponent.hasPrefix("AM-DL") && isDirectory($0)
            })
        }
        return uniqueURLs(roots)
    }

    func snapshotAudioFiles(in workingDirectory: URL) -> [URL: FileSignature] {
        var snapshot: [URL: FileSignature] = [:]
        for root in sourceRoots(in: workingDirectory) {
            for file in enumerateAudioFiles(in: root) {
                if let signature = signature(of: file) {
                    snapshot[file] = signature
                }
            }
        }
        return snapshot
    }

    func changedAudioFiles(
        in workingDirectory: URL,
        comparedTo previous: [URL: FileSignature]
    ) -> [(url: URL, root: URL)] {
        var changed: [(url: URL, root: URL)] = []
        for root in sourceRoots(in: workingDirectory) {
            for file in enumerateAudioFiles(in: root) {
                guard let current = signature(of: file) else { continue }
                if previous[file] != current {
                    changed.append((file, root))
                }
            }
        }
        return changed.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Count only stable, playable outputs; a partially downloaded m4a must
    /// not become a completed song merely because its filename exists.
    func downloadProgress(in directory: URL, comparedTo baseline: [URL: FileSignature],
                          lastScan: [URL: FileSignature], verified: [URL: FileSignature])
        -> (current: [URL: FileSignature], verified: [URL: FileSignature]) {
        var current: [URL: FileSignature] = [:]
        var valid: [URL: FileSignature] = [:]
        for item in changedAudioFiles(in: directory, comparedTo: baseline) {
            guard let stamp = signature(of: item.url) else { continue }
            current[item.url] = stamp
            if verified[item.url] == stamp || (lastScan[item.url] == stamp && inspect(item.url).playable) {
                valid[item.url] = stamp
            }
        }
        return (current, valid)
    }

    /// Returns every downloaded audio file with its source root. The manual
    /// iPod action uses this full view so it can detect files imported during
    /// an earlier session as well as files from the current download.
    func audioFiles(in workingDirectory: URL) -> [(url: URL, root: URL)] {
        var files: [(url: URL, root: URL)] = []
        for root in sourceRoots(in: workingDirectory) {
            files.append(contentsOf: enumerateAudioFiles(in: root).map { (url: $0, root: root) })
        }
        return files.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    func importFiles(
        _ files: [(url: URL, root: URL)],
        to device: IPodDevice,
        expectedSignatures: [URL: FileSignature] = [:],
        playlistID: String? = nil,
        playlistName: String? = nil,
        onProgress: @Sendable (IPodImportProgress) -> Void = { _ in }
    ) -> IPodImportReport {
        let fileManager = FileManager.default
        var imported = 0
        var alreadyPresent = 0
        var skippedUnplayable = 0
        var failedFiles = 0
        var missingSourceCovers = 0
        var missingDestinationCovers = 0
        var missingBitrateFiles = Set<String>()
        var messages: [String] = []
        var copiedSourceDirectories = Set<String>()
        var copiedDestinations: [URL] = []
        var libraryInstruction: String?
        var playlistInstruction: String?
        var processed = 0
        var interrupted = false
        do {
            try validateFilesystem(on: device)
        } catch {
            interrupted = true
            messages.append("无法读取 iPod 目录，已停止导入。请安全弹出后重新连接；若仍报错，请先检查设备文件系统。")
        }
        func emit(_ stage: IPodImportProgress.Stage, _ filename: String = "", fraction: Double) {
            onProgress(IPodImportProgress(stage: stage, total: files.count, processed: processed,
                                          imported: imported, existing: alreadyPresent,
                                          filename: filename, fraction: fraction))
        }

        for item in files {
            guard !interrupted else { break }
            guard deviceAvailable(device) else {
                interrupted = true
                messages.append("设备已断开、已被替换或变为只读，已停止导入。")
                break
            }
            emit(.copying, item.url.lastPathComponent, fraction: 0.75 * Double(processed) / Double(max(1, files.count)))
            defer {
                processed += 1
                emit(.copying, item.url.lastPathComponent, fraction: 0.75 * Double(processed) / Double(max(1, files.count)))
            }
            guard let destination = safeDestination(for: item.url, sourceRoot: item.root, device: device) else {
                failedFiles += 1
                messages.append("跳过超出来源或设备目录的文件。")
                continue
            }
            if let expected = expectedSignatures[item.url], signature(of: item.url) != expected {
                interrupted = true
                messages.append("源文件在预览后变化，已停止：\(item.url.lastPathComponent)")
                break
            }
            let sourceCheck = inspect(item.url)
            if !sourceCheck.playable {
                skippedUnplayable += 1
                messages.append("跳过无法识别或读取的音频（请检查文件及 ffprobe）：\(item.url.lastPathComponent)")
                continue
            }
            if let reason = Self.rockboxFormatIssue(extension: item.url.pathExtension, codec: sourceCheck.codec, container: sourceCheck.container) {
                skippedUnplayable += 1
                messages.append("跳过 \(item.url.lastPathComponent)：\(reason)")
                continue
            }
            if !sourceCheck.hasEmbeddedCover {
                missingSourceCovers += 1
            }
            if sourceCheck.bitrate == nil {
                missingBitrateFiles.insert(item.url.path)
            }

            do {
                guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    let sameSize = signature(of: destination)?.size == signature(of: item.url)?.size
                    if try sameSize && Self.sameContents(item.url, destination) {
                        alreadyPresent += 1
                    } else {
                        failedFiles += 1
                        messages.append("跳过同名但内容不同的设备文件：\(item.url.lastPathComponent)")
                        continue
                    }
                } else {
                    try copyAtomically(item.url, to: destination, device: device)
                    imported += 1
                }
                copiedDestinations.append(destination)
                copiedSourceDirectories.insert(item.url.deletingLastPathComponent().path)
            } catch {
                failedFiles += 1
                messages.append("导入失败：\(item.url.lastPathComponent)（\(error.localizedDescription)）")
                if Self.isDeviceIOError(error) {
                    interrupted = true
                    messages.append("设备发生输入/输出错误，已停止后续写入；请安全弹出后重新连接。")
                    break
                }
            }
        }

        // Rockbox themes commonly use a folder-level cover.jpg. Preserve it
        // beside imported tracks when the download produced one. A same-name
        // .jpg beside a track (the layout playlist imports prepare) is that
        // track's own artwork and travels with its song.
        var copiedCoverDirectories = Set<String>()
        emit(.covers, fraction: 0.75)
        for item in files where copiedSourceDirectories.contains(item.url.deletingLastPathComponent().path) {
            guard !interrupted, deviceAvailable(device) else { interrupted = true; break }
            let sidecar = item.url.deletingPathExtension().appendingPathExtension("jpg")
            if fileManager.fileExists(atPath: sidecar.path),
               let destinationSidecar = safeDestination(for: sidecar, sourceRoot: item.root, device: device) {
                do {
                    try fileManager.createDirectory(
                        at: destinationSidecar.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if !fileManager.fileExists(atPath: destinationSidecar.path) {
                        try copyAtomically(sidecar, to: destinationSidecar, device: device)
                    }
                } catch {
                    messages.append("封面复制失败：\(sidecar.lastPathComponent)")
                    if Self.isDeviceIOError(error) { interrupted = true; break }
                }
            }
            let sourceCover = item.url.deletingLastPathComponent().appendingPathComponent("cover.jpg")
            guard fileManager.fileExists(atPath: sourceCover.path) else { continue }
            guard copiedCoverDirectories.insert(sourceCover.deletingLastPathComponent().path).inserted else { continue }
            guard let destinationCover = safeDestination(for: sourceCover, sourceRoot: item.root, device: device) else { continue }
            do {
                try fileManager.createDirectory(
                    at: destinationCover.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !fileManager.fileExists(atPath: destinationCover.path) {
                    try copyAtomically(sourceCover, to: destinationCover, device: device)
                }
            } catch {
                messages.append("封面复制失败：\(sourceCover.lastPathComponent)")
                if Self.isDeviceIOError(error) { interrupted = true; break }
            }
        }

        var verifiedDestinations: [URL] = []
        for (index, destination) in copiedDestinations.enumerated() {
            guard !interrupted, deviceAvailable(device) else { interrupted = true; break }
            emit(.verifying, destination.lastPathComponent,
                 fraction: 0.76 + 0.23 * Double(index) / Double(max(1, copiedDestinations.count)))
            let check = inspect(destination)
            if !check.hasEmbeddedCover { missingDestinationCovers += 1 }
            if check.bitrate == nil { missingBitrateFiles.insert(destination.path) }
            if !check.playable {
                messages.append("设备文件校验失败：\(destination.lastPathComponent)")
                failedFiles += 1
            } else { verifiedDestinations.append(destination) }
        }

        if let playlistID, !interrupted, failedFiles == 0, skippedUnplayable == 0,
           verifiedDestinations.count == files.count, !files.isEmpty {
            do {
                let name = try writePlaylist(id: playlistID, name: playlistName, destinations: verifiedDestinations, device: device)
                playlistInstruction = "M3U8 歌单 \(name) 已就绪；设备端顺序尚待验证。"
            } catch {
                messages.append("歌曲已复制，歌单文件未生成：\(error.localizedDescription)")
            }
        }

        // The device owns its database and configuration. File copying does not
        // prove that its scanner or PictureFlow has processed the new tracks.
        if !interrupted && !copiedDestinations.isEmpty {
            emit(.library, fraction: 0.99)
            let initialized = fileManager.fileExists(atPath: device.rootURL.appendingPathComponent(".rockbox/database_idx.tcd").path)
            libraryInstruction = initialized
                ? "文件已复制；请安全弹出，在 Rockbox「数据库」中更新。封面索引如有需要请在设备上更新。"
                : "文件已复制；请安全弹出，在 Rockbox「数据库」中初始化并按设备提示操作。设备端播放及封面尚未验证。"
            if let playlistInstruction { libraryInstruction! += " " + playlistInstruction }
        }

        return IPodImportReport(
            deviceName: device.name,
            imported: imported,
            alreadyPresent: alreadyPresent,
            skippedUnplayable: skippedUnplayable,
            failedFiles: failedFiles,
            processedFiles: processed,
            missingSourceCovers: missingSourceCovers,
            missingDestinationCovers: missingDestinationCovers,
            missingBitrates: missingBitrateFiles.count,
            sourceFiles: files.count,
            warningCount: messages.count,
            messages: Array(messages.prefix(20)),
            libraryInstruction: libraryInstruction,
            interrupted: interrupted
        )
    }

    private func writePlaylist(id: String, name: String?, destinations: [URL], device: IPodDevice) throws -> String {
        guard !id.isEmpty, id.count <= 32, id.allSatisfy(\.isNumber), deviceAvailable(device),
              let volume = canonicalURL(device.rootURL), let music = canonicalURL(device.musicURL),
              music.path == volume.appendingPathComponent("Music").path else { throw ImportError.deviceUnavailable }
        let entries = try destinations.map { url -> String in
            guard let resolved = canonicalURL(url), resolved.path.hasPrefix(music.path + "/"),
                  !resolved.path.contains("\n"), !resolved.path.contains("\r") else { throw ImportError.deviceUnavailable }
            return String(resolved.path.dropFirst(volume.path.count))
        }
        let content = Data(("#EXTM3U\n" + entries.joined(separator: "\n") + "\n").utf8)
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        let safeName = String((name ?? "").filter { $0.unicodeScalars.allSatisfy { !forbidden.contains($0) } }.prefix(32))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = safeName.isEmpty ? "MusicBridge-\(id)" : "\(safeName)-\(id)"
        var output = music.appendingPathComponent("\(prefix).m3u8")
        guard canonicalURL(output)?.path == output.path else { throw ImportError.deviceUnavailable }
        if FileManager.default.fileExists(atPath: output.path) {
            if (try? Data(contentsOf: output)) == content { return output.lastPathComponent }
            output = music.appendingPathComponent("\(prefix)-\(UUID().uuidString).m3u8")
            guard canonicalURL(output)?.path == output.path else { throw ImportError.deviceUnavailable }
        }
        let staging = music.appendingPathComponent(".musicbridge-\(UUID().uuidString).tmp")
        defer { if deviceAvailable(device) { try? FileManager.default.removeItem(at: staging) } }
        try content.write(to: staging, options: .withoutOverwriting)
        guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
        try FileManager.default.moveItem(at: staging, to: output)
        return output.lastPathComponent
    }

    static func rockboxFormatIssue(extension ext: String, codec: String?, container: String? = nil) -> String? {
        let ext = ext.lowercased()
        let allowed: Set<String>?
        switch ext {
        case "m4a", "mp4": allowed = ["aac", "alac"]
        case "aac": allowed = ["aac"]
        case "flac": allowed = ["flac"]
        default: allowed = nil // Preserve existing support for other formats.
        }
        guard let allowed else { return nil }
        guard let codec, allowed.contains(codec.lowercased()) else {
            return "编码与容器不在当前 AAC、ALAC、FLAC 适配范围内"
        }
        if let container {
            let names = Set(container.lowercased().split(separator: ",").map(String.init))
            let expected = ext == "flac" ? "flac" : ext == "aac" ? "aac" : "mp4"
            if !names.contains(expected) { return "实际容器与文件扩展名不一致" }
        }
        return nil
    }

    func validateFilesystem(on device: IPodDevice) throws {
        guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
        let manager = FileManager.default
        let entries = try manager.contentsOfDirectory(at: device.rootURL, includingPropertiesForKeys: nil)
        if entries.contains(where: { $0.lastPathComponent == "Music" }) {
            _ = try manager.contentsOfDirectory(at: device.musicURL, includingPropertiesForKeys: nil)
        }
        if device.isRockbox {
            _ = try manager.contentsOfDirectory(at: device.rootURL.appendingPathComponent(".rockbox"), includingPropertiesForKeys: nil)
        }
    }

    static func isDeviceIOError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain && [5, 6, 19, 30].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error { return isDeviceIOError(underlying) }
        return false
    }

    /// PictureFlow maintains a separate album index. A database update alone
    /// does not invalidate it; request its supported rebuild on next launch.
    private func requestPictureFlowRebuild(on device: IPodDevice) throws {
        let relative = ".rockbox/rocks/demos/pictureflow.cfg"
        let config = device.rootURL.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: config.path) else { return }
        guard deviceAvailable(device), let volume = canonicalURL(device.rootURL),
              canonicalURL(config)?.path == volume.appendingPathComponent(relative).path else {
            throw ImportError.deviceUnavailable
        }
        let original = try String(contentsOf: config, encoding: .utf8)
        let updated = Self.pictureFlowRebuildConfiguration(original)
        guard original != updated else { return }
        let backup = config.deletingLastPathComponent().appendingPathComponent("pictureflow.musicbridge-\(UUID().uuidString).bak")
        try FileManager.default.copyItem(at: config, to: backup)
        guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
        try updated.write(to: config, atomically: true, encoding: .utf8)
    }

    static func pictureFlowRebuildConfiguration(_ original: String) -> String {
        var result = original
        for key in ["cache version", "last album", "art cache pos", "art cache inspected"] {
            let pattern = "(?m)^" + key + ":[^\\r\\n]*"
            if result.range(of: pattern, options: .regularExpression) != nil {
                result = result.replacingOccurrences(of: pattern, with: key + ": 0", options: .regularExpression)
            } else {
                if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
                result += key + ": 0\n"
            }
        }
        return result
    }

    static func libraryConfiguration(_ original: String) -> String {
        var lines = original.components(separatedBy: "\n")
        var paths = "/"
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.first?.trimmingCharacters(in: .whitespaces) == "database scan paths", parts.count == 2 {
                paths = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let roots = paths.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        if !roots.contains("/") && !roots.contains("/Music") {
            paths = (roots + ["/Music"]).joined(separator: ":")
        }
        lines.removeAll { line in
            let key = line.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
            return key == "tagcache_autoupdate" || key == "database scan paths"
        }
        while lines.last == "" { lines.removeLast() }
        lines.append("tagcache_autoupdate: on")
        lines.append("database scan paths: \(paths)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Resolve both sides before writing; a symlink must never escape Music/.
    @discardableResult
    func archiveLegacyImports(_ originals: [(url: URL, root: URL)], playlistID: String,
                              on device: IPodDevice) throws -> Int {
        guard !playlistID.isEmpty, playlistID.allSatisfy(\.isNumber), deviceAvailable(device),
              device.isRockbox, let volume = canonicalURL(device.rootURL),
              let music = canonicalURL(device.musicURL) else { throw ImportError.deviceUnavailable }
        let relative = ".rockbox/musicbridge-originals/\(playlistID)/\(UUID().uuidString)"
        let archive = device.rootURL.appendingPathComponent(relative)
        guard canonicalURL(archive)?.path == volume.appendingPathComponent(relative).path else { throw ImportError.deviceUnavailable }
        let manager = FileManager.default
        var moved = 0
        // Only the exact former import destinations, with source-sized files,
        // may move. Keep a recoverable copy outside the scanned music tree.
        for original in originals {
            guard let old = safeDestination(for: original.url, sourceRoot: original.root, device: device),
                  old.path.hasPrefix(music.path + "/"), manager.fileExists(atPath: old.path),
                  signature(of: old)?.size == signature(of: original.url)?.size else { continue }
            guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
            let tail = String(old.path.dropFirst(music.path.count + 1))
            let destination = archive.appendingPathComponent(tail)
            guard canonicalURL(destination)?.path.hasPrefix(archive.path + "/") == true else { throw ImportError.deviceUnavailable }
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ignore = archive.appendingPathComponent("database.ignore")
            if !manager.fileExists(atPath: ignore.path) {
                try Data().write(to: ignore, options: .withoutOverwriting)
            }
            try manager.moveItem(at: old, to: destination)
            moved += 1
        }
        return moved
    }

    static func isDatabaseIndexName(_ name: String) -> Bool {
        name.range(of: "\\Adatabase_(?:[0-9]+|idx|state|tmp)\\.tcd\\z", options: .regularExpression) != nil
    }

    /// Incremental updates retain album strings that PictureFlow can still
    /// enumerate. After removing legacy tracks, a fresh tag database is needed.
    /// Keep verified Mac and device backups before retiring the old indexes.
    @discardableResult
    func resetDatabase(on device: IPodDevice, backupDirectory: URL) throws -> Int {
        try validateFilesystem(on: device)
        guard device.isRockbox, let volume = canonicalURL(device.rootURL) else { throw ImportError.deviceUnavailable }
        let rockbox = device.rootURL.appendingPathComponent(".rockbox")
        guard canonicalURL(rockbox)?.path == volume.appendingPathComponent(".rockbox").path,
              !backupDirectory.resolvingSymlinksInPath().path.hasPrefix(volume.path + "/") else { throw ImportError.deviceUnavailable }
        let manager = FileManager.default
        let database = try manager.contentsOfDirectory(at: rockbox, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { Self.isDatabaseIndexName($0.lastPathComponent) }
        let pictureIndex = rockbox.appendingPathComponent("rocks/demos/pictureflow/pictureflow_album.idx")
        let pictureConfig = rockbox.appendingPathComponent("rocks/demos/pictureflow.cfg")
        let retired = database + (manager.fileExists(atPath: pictureIndex.path) ? [pictureIndex] : [])
        let backups = retired + (manager.fileExists(atPath: pictureConfig.path) ? [pictureConfig] : [])
        guard !manager.fileExists(atPath: backupDirectory.path) else { throw ImportError.backupFailed }
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for file in backups {
            guard let resolved = canonicalURL(file), resolved.path == file.path,
                  resolved.path.hasPrefix(volume.path + "/.rockbox/"),
                  let stamp = signature(of: file) else { throw ImportError.backupFailed }
            let tail = String(file.path.dropFirst(rockbox.path.count + 1))
            let copy = backupDirectory.appendingPathComponent(tail)
            try manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: file, to: copy)
            guard signature(of: copy)?.size == stamp.size,
                  signature(of: file) == stamp else { throw ImportError.backupFailed }
        }
        let archive = rockbox.appendingPathComponent("musicbridge-database-backups/\(UUID().uuidString)")
        guard canonicalURL(archive)?.path.hasPrefix(volume.path + "/.rockbox/musicbridge-database-backups/") == true else {
            throw ImportError.deviceUnavailable
        }
        for file in retired {
            guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
            let destination = archive.appendingPathComponent(String(file.path.dropFirst(rockbox.path.count + 1)))
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: file, to: destination)
        }
        try requestPictureFlowRebuild(on: device)
        return database.count
    }

    func safeDestination(for source: URL, sourceRoot: URL, device: IPodDevice) -> URL? {
        guard let root = canonicalURL(sourceRoot), let file = canonicalURL(source) else { return nil }
        guard file.path.hasPrefix(root.path + "/") else { return nil }
        let relative = relativePath(of: file, from: root)
        let music = device.musicURL.standardizedFileURL
        guard let volume = canonicalURL(device.rootURL), let resolvedMusic = canonicalURL(music) else { return nil }
        guard resolvedMusic.path.hasPrefix(volume.path + "/") else { return nil }
        guard let destination = canonicalURL(music.appendingPathComponent(relative)) else { return nil }
        guard destination.path.hasPrefix(resolvedMusic.path + "/") else { return nil }
        return destination
    }

    /// Foundation may leave an intermediate symlink unresolved when the final
    /// file does not exist yet. Resolve every existing prefix before copying.
    private func canonicalURL(_ url: URL) -> URL? {
        var remaining = Array(url.pathComponents.dropFirst())
        var resolved = URL(fileURLWithPath: "/", isDirectory: true)
        var links = 0
        while !remaining.isEmpty {
            let part = remaining.removeFirst()
            if part == "." { continue }
            if part == ".." { resolved.deleteLastPathComponent(); continue }
            resolved.appendPathComponent(part)
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: resolved.path) {
                links += 1
                guard links <= 32 else { return nil }
                let link = URL(fileURLWithPath: target, relativeTo: resolved.deletingLastPathComponent())
                remaining = Array(link.pathComponents.dropFirst()) + remaining
                resolved = URL(fileURLWithPath: "/", isDirectory: true)
            }
        }
        // Do not call standardizedFileURL here: on macOS it may rewrite
        // existing /private/var paths to /var but leave missing tails alone.
        return resolved
    }

    private func deviceAvailable(_ device: IPodDevice) -> Bool {
        guard device.canImport,
              let values = try? device.rootURL.resourceValues(forKeys: [.isVolumeKey, .volumeIsReadOnlyKey, .volumeUUIDStringKey]),
              values.isVolume == true, values.volumeIsReadOnly == false,
              device.volumeIdentifier == nil || values.volumeUUIDString == device.volumeIdentifier else { return false }
        return FileManager.default.isWritableFile(atPath: device.rootURL.path)
    }

    private func copyAtomically(_ source: URL, to destination: URL, device: IPodDevice) throws {
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".musicbridge-\(UUID().uuidString).partial")
        defer {
            // Only our own staging file, and only on the same still-mounted device.
            if deviceAvailable(device) { try? FileManager.default.removeItem(at: staging) }
        }
        guard let resolvedSource = canonicalURL(source) else { throw ImportError.deviceUnavailable }
        try FileManager.default.copyItem(at: resolvedSource, to: staging)
        guard deviceAvailable(device) else { throw ImportError.deviceUnavailable }
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private enum ImportError: LocalizedError {
        case deviceUnavailable
        case backupFailed
        var errorDescription: String? {
            switch self {
            case .deviceUnavailable: return "设备已断开或不可写，已停止操作。"
            case .backupFailed: return "数据库备份校验未通过，已停止重置。"
            }
        }
    }

    /// Post-download health check for one file, reusing the same ffprobe
    /// inspection as the import path: playable, codec, sample rate, duration.
    func healthCheck(_ url: URL) -> MediaCheckResult { inspect(url) }

    private func inspect(_ url: URL) -> MediaCheckResult {
        guard let ffprobe = findFFProbe() else {
            return MediaCheckResult(playable: false, bitrate: nil, hasEmbeddedCover: false, codec: nil)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobe)
        process.arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name,sample_rate,disposition:format=bit_rate,format_name,duration",
            "-of", "json",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
            defer { timeout.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return MediaCheckResult(playable: false, bitrate: nil, hasEmbeddedCover: false, codec: nil)
            }
            let output = try JSONDecoder().decode(ProbeOutput.self, from: data)
            let audio = output.streams.first { $0.codecType == "audio" }
            let bitrate = Int(output.format?.bitRate ?? "") ?? audio?.bitRate.flatMap(Int.init)
            let hasCover = output.streams.contains {
                $0.codecType == "video" || $0.disposition?.attachedPic == 1
            }
            return MediaCheckResult(
                playable: audio != nil,
                bitrate: bitrate,
                hasEmbeddedCover: hasCover,
                codec: audio?.codecName,
                container: output.format?.formatName,
                durationSeconds: Double(output.format?.duration ?? ""),
                sampleRate: audio?.sampleRate.flatMap(Int.init)
            )
        } catch {
            return MediaCheckResult(playable: false, bitrate: nil, hasEmbeddedCover: false, codec: nil)
        }
    }

    private func findFFProbe() -> String? {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func enumerateAudioFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard
                  !url.lastPathComponent.hasPrefix("."),
                  url.pathExtension.lowercased() != "",
                  audioExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(url)
        }
        return files
    }

    private func signature(of url: URL) -> FileSignature? {
        guard let values = try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize,
              let modificationDate = values.contentModificationDate else { return nil }
        return FileSignature(size: UInt64(size), modificationDate: modificationDate)
    }

    private func relativePath(of url: URL, from root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var relative = String(url.path.dropFirst(prefix.count))
        var components = relative.split(separator: "/").map(String.init)
        if components.first == "Apple Music" {
            components.removeFirst()
        }
        relative = components.joined(separator: "/")
        return relative.isEmpty ? url.lastPathComponent : relative
    }

    private func yamlValue(_ contents: String, key: String) -> String? {
        guard let line = contents.split(whereSeparator: \.isNewline).first(where: {
            String($0).trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
        }) else { return nil }
        let value = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .joined(separator: ":")
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

enum RockboxPreviewError: LocalizedError {
    case insufficientSpace
    var errorDescription: String? {
        switch self {
        case .insufficientSpace: return "设备可用空间不足，请释放空间后重新预览。"
        }
    }
}

private struct ProbeOutput: Decodable {
    let streams: [ProbeStream]
    let format: ProbeFormat?
}

private struct ProbeStream: Decodable {
    let codecType: String?
    let codecName: String?
    let bitRate: String?
    let sampleRate: String?
    let disposition: ProbeDisposition?

    enum CodingKeys: String, CodingKey {
        case codecType = "codec_type"
        case codecName = "codec_name"
        case bitRate = "bit_rate"
        case sampleRate = "sample_rate"
        case disposition
    }
}

private struct ProbeDisposition: Decodable {
    let attachedPic: Int?

    enum CodingKeys: String, CodingKey {
        case attachedPic = "attached_pic"
    }
}

private struct ProbeFormat: Decodable {
    let bitRate: String?
    let formatName: String?
    let duration: String?

    enum CodingKeys: String, CodingKey {
        case bitRate = "bit_rate"
        case formatName = "format_name"
        case duration
    }
}
