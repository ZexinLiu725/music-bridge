import Foundation

enum NativeEngineChecks {
    static func run() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let engine = NativeIPodImporter(root: repo).engineURL() else {
            print("SKIP: real podkit contract checks (engine not installed)")
            return
        }
        let manager = FileManager.default
        // Keep this isolated fixture beneath work/ to avoid macOS /var ->
        // /private/var URL aliasing in the production symlink protection checks.
        let base = repo.appendingPathComponent("work/native-engine-checks/\(UUID())")
        defer { try? manager.removeItem(at: base) }
        let volume = base.appendingPathComponent("synthetic-device")
        let info = volume.appendingPathComponent("iPod_Control/Device")
        let source = base.appendingPathComponent("music 含空格")
        let stage = base.appendingPathComponent("strict-import")
        try manager.createDirectory(at: info, withIntermediateDirectories: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        // Synthetic Video-model fixture. This is an ordinary temporary directory,
        // never a connected iPod or a mounted user volume.
        try "ModelNumStr: MA002\nFirewireGuid: 0x000A27001A2B3C4D\n".write(to: info.appendingPathComponent("SysInfo"), atomically: true, encoding: .utf8)
        let config = base.appendingPathComponent("config.toml")
        try NativeIPodImporter.configuration(source: stage).write(to: config, atomically: true, encoding: .utf8)
        var fixture = IPodDevice(name: "Synthetic", rootURL: volume, musicURL: volume.appendingPathComponent("Music"),
                                 writeState: .writable, isRockbox: false, hasNativeDatabase: true, identity: IPodKnowledge.read(at: volume))
        func invoke(_ binary: URL, _ args: [String]) throws -> (Int32, Data) {
            let task = Process(); task.executableURL = binary; task.arguments = args
            task.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PODKIT_") }
            task.standardInput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            let pipe = Pipe(); task.standardOutput = pipe
            try task.run()
            let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: timeout)
            defer { timeout.cancel() }
            let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            return (task.terminationStatus, output)
        }
        let version = try invoke(engine, ["--version"])
        precondition(version.0 == 0 && String(data: version.1, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "0.6.0")
        let common = ["--config", config.path, "--device", volume.path, "--json", "--no-color", "--no-tips"]
        let initialized = try invoke(engine, common + ["device", "init"])
        precondition(initialized.0 == 0)
        for (file, codec, title) in [("copy.mp3", "libmp3lame", "直接复制"), ("convert.flac", "flac", "需要转码")] {
            let generated = try invoke(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
                ["-nostdin", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=997:sample_rate=44100", "-t", "0.1", "-ac", "2", "-c:a", codec,
                 "-metadata", "title=\(title)", "-metadata", "artist=测试歌手", "-metadata", "album=保留原专辑", source.appendingPathComponent(file).path])
            precondition(generated.0 == 0)
        }
        let originals = try ["copy.mp3", "convert.flac"].map { try Data(contentsOf: source.appendingPathComponent($0)) }
        let assessed = try NativeAudioPlanner().assess(["copy.mp3", "convert.flac"].map { (source.appendingPathComponent($0), source) }, device: fixture) { _ in }
        precondition(assessed.ready.count == 2 && assessed.sameSpecCount == 1 && assessed.lossyCount == 1)
        try manager.copyItem(at: source.appendingPathComponent("copy.mp3"), to: stage.appendingPathComponent("copy.mp3"))
        let lossless = assessed.ready.first { $0.disposition == .sameSpecALAC }!
        let target = NativeAudioSpec(codec: "alac", bits: 16, rate: 44100, channels: 2)
        _ = try NativeAudioTools.convert(lossless, to: stage.appendingPathComponent("lossless.m4a"), target: target)
        func pcm(_ url: URL) throws -> Data {
            let result = try invoke(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ["-v", "error", "-i", url.path, "-map", "0:a:0", "-f", "s16le", "-"])
            precondition(result.0 == 0); return result.1
        }
        let sourcePCM = try pcm(lossless.url), outputPCM = try pcm(stage.appendingPathComponent("lossless.m4a"))
        precondition(sourcePCM == outputPCM)
        let hires = source.appendingPathComponent("hires.flac")
        let generated = try invoke(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=96000", "-t", "0.1", "-ac", "2", "-c:a", "flac", "-sample_fmt", "s32", hires.path])
        precondition(generated.0 == 0)
        let highAssessment = try NativeAudioPlanner().assess([(hires, source)], device: fixture) { _ in }
        precondition(highAssessment.ready.isEmpty && highAssessment.pending.count == 1)
        let high = highAssessment.pending[0]
        _ = try NativeAudioTools.convert(high, to: base.appendingPathComponent("converted/high.m4a"), target: high.target!)
        let convertedSpec = try NativeAudioTools.probe(base.appendingPathComponent("converted/high.m4a"))
        precondition(convertedSpec == target)
        let db = volume.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        let initialDatabase = try Data(contentsOf: db)
        let preview = try invoke(engine, NativeIPodImporter.arguments(config: config, device: fixture, dryRun: true))
        precondition(preview.0 == 0)
        let plan = try NativeIPodImporter.parsePlan(preview.1, sourceCount: 2)
        precondition(plan.additions == 2 && plan.conversions == 0)
        let afterPreview = try Data(contentsOf: db)
        precondition(initialDatabase == afterPreview)
        let written = try invoke(engine, NativeIPodImporter.arguments(config: config, device: fixture, dryRun: false))
        let completed = try NativeIPodImporter.parseResult(written.1, exitStatus: written.0)
        precondition(completed == 2)
        let readback = try invoke(engine, common + ["device", "music", "--tracks"])
        let tracks = try JSONSerialization.jsonObject(with: readback.1) as! [[String: Any]]
        precondition(readback.0 == 0 && tracks.count == 2)
        precondition(tracks.allSatisfy { $0["album"] as? String == "保留原专辑" && $0["hasFile"] as? Bool == true })
        let repeated = try invoke(engine, NativeIPodImporter.arguments(config: config, device: fixture, dryRun: true))
        let repeatPlan = try NativeIPodImporter.parsePlan(repeated.1, sourceCount: 2)
        precondition(repeated.0 == 0 && repeatPlan.additions == 0 && repeatPlan.existing == 2)
        let finalOriginals = try ["copy.mp3", "convert.flac"].map { try Data(contentsOf: source.appendingPathComponent($0)) }
        precondition(originals == finalOriginals)
        let service = NativeIPodImporter(root: repo, mountValidator: { device in
            guard device.rootURL == volume else { throw NativeImportError.invalidDevice }
        })
        // libgpod initialization may normalize device metadata. Use the identity
        // observed after fixture initialization, as the actual mount scanner does.
        fixture.identity = IPodKnowledge.read(at: volume)
        precondition(fixture.identity.permitsNativeImport)
        let firstPlan = try service.prepare(files: ["copy.mp3", "convert.flac", "hires.flac"].map { (source.appendingPathComponent($0), source) },
            device: fixture, missing: 0) { _ in }
        defer { try? manager.removeItem(at: firstPlan.workspace) }
        precondition(firstPlan.sourceCount == 2 && firstPlan.assessment?.pending.count == 1)
        let firstResult = try service.execute(firstPlan) { _ in }
        precondition(firstResult.completed == 0 && firstResult.existing == 2 && firstResult.backup == nil)
        let playlist = PlaylistSelection(id: "synthetic", name: "测试歌单", sourceURL: URL(string: "https://example.invalid/playlist")!,
            coverURL: URL(string: "https://example.invalid/cover.jpg")!, tracks: [
                .init(title: "需要转码", artist: "测试歌手"), .init(title: "直接复制", artist: "测试歌手")], sourceTrackCount: 2)
        let playlistPlan = try service.prepare(files: ["copy.mp3", "convert.flac"].map { (source.appendingPathComponent($0), source) },
            device: fixture, missing: 0, playlist: playlist) { _ in }
        defer { try? manager.removeItem(at: playlistPlan.workspace) }
        let playlistResult = try service.execute(playlistPlan) { _ in }
        precondition(playlistResult.completed == 0 && playlistResult.playlistCount == 2 && playlistResult.backup != nil)
        let library = NativeLibraryService(root: repo, mountValidator: { device in
            guard device.rootURL == volume else { throw NativeImportError.invalidDevice }
        })
        let inspected = try library.playlist(playlist, device: fixture, save: false)
        precondition(!inspected.changed && inspected.count == 2 && inspected.files.count == 2)
        precondition(inspected.titles == ["需要转码", "直接复制"])
        let beforeConflict = try Data(contentsOf: db)
        var conflicting = playlist; conflicting.tracks.removeLast()
        do { _ = try library.playlist(conflicting, device: fixture, save: true); preconditionFailure("Unrelated membership must not be replaced") }
        catch { let after = try Data(contentsOf: db); precondition(after == beforeConflict) }
        let repeatedPlaylistPlan = try service.prepare(files: ["copy.mp3", "convert.flac"].map { (source.appendingPathComponent($0), source) },
            device: fixture, missing: 0, playlist: playlist) { _ in }
        defer { try? manager.removeItem(at: repeatedPlaylistPlan.workspace) }
        let repeatedPlaylist = try service.execute(repeatedPlaylistPlan) { _ in }
        precondition(repeatedPlaylist.backup == nil && repeatedPlaylist.completed == 0 && repeatedPlaylist.playlistCount == 2)
        let afterRepeatedPlaylist = try Data(contentsOf: db)
        precondition(afterRepeatedPlaylist == beforeConflict)
        try NativeWorkflowChecks.run(repo: repo, base: base)
        let conversionPlan = try service.prepare(files: [(base.appendingPathComponent("converted/high.m4a"), base)], device: fixture, missing: 0) { _ in }
        defer { try? manager.removeItem(at: conversionPlan.workspace) }
        let convertedResult = try service.execute(conversionPlan) { _ in }
        precondition(convertedResult.completed == 1 && convertedResult.backup != nil)
        precondition(manager.fileExists(atPath: conversionPlan.backupURL.appendingPathComponent("iTunes/iTunesDB").path))
        let afterSecondStage = try invoke(engine, common + ["device", "music", "--tracks"])
        let allTracks = try JSONSerialization.jsonObject(with: afterSecondStage.1) as! [[String: Any]]
        precondition(afterSecondStage.0 == 0 && allTracks.count == 3)
        print("PASS: strict ALAC PCM equality; high-resolution deferral; \(NativeAudioTools.resamplerName) + 16-bit conversion; engine copy-only plan; readback/repeat; originals preserved")
        print("PASS: production importer with isolated mount validator; ready/deferred split; no-op first stage; second-stage database backup/write/readback")
    }
}
