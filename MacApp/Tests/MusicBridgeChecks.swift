import Foundation

@main
struct BridgeChecks {
    @MainActor
    static func main() async throws {
        precondition(PlaylistSource.identify("https://music.apple.com/cn/playlist/example/pl.abc") == .apple)
        precondition(PlaylistSource.identify("https://music.163.com/#/playlist?id=123") == .netease)
        precondition(PlaylistSource.identify("https://music.163.com/playlist?id=123") == .netease)
        precondition(PlaylistSource.identify("分享张国荣的专辑《REMEMBRANCE Leslie》https://163cn.tv/bjJ68pFq (@网易云音乐)") == .netease)
        precondition(PlaylistSource.identify("https://music.163.com/album?id=162353328") == .netease)
        precondition(PlaylistSource.identify("https://music.163.com/song?id=456") == .netease)
        precondition(PlaylistSource.identify("https://music.163.com/#/song?id=456") == .netease)
        precondition(PlaylistSource.identify("https://music.apple.com/cn/song/example/123456") == .apple)
        precondition(PlaylistSource.identify("https://music.apple.com/cn/album/example/123456?i=789") == .apple)
        let albumJSON = Data("""
        {"code":200,"album":{"id":162353328,"name":"REMEMBRANCE Leslie","size":2,"picUrl":"https://example.com/a.jpg"},"songs":[{"name":"第一首","ar":[{"name":"张国荣"}]},{"name":"第二首","ar":[{"name":"张国荣"}]}]}
        """.utf8)
        let album = try PlaylistSelection.parseAlbum(albumJSON, id: "162353328")
        precondition(album.name == "REMEMBRANCE Leslie" && album.tracks.map(\.title) == ["第一首", "第二首"])
        do { _ = try PlaylistSelection.parseAlbum(albumJSON, id: "1"); preconditionFailure("Wrong album accepted") } catch {}
        let songJSON = Data("""
        {"code":200,"songs":[{"id":456,"name":"单曲一首","ar":[{"name":"歌手甲"}],"al":{"name":"某专辑","picUrl":"https://example.com/s.jpg"},"dt":123000}]}
        """.utf8)
        let song = try PlaylistSelection.parseSong(songJSON, id: "456")
        precondition(song.name == "单曲一首" && song.tracks.count == 1 && song.tracks[0].neteaseID == "456" && song.tracks[0].durationMs == 123000)
        do { _ = try PlaylistSelection.parseSong(songJSON, id: "1"); preconditionFailure("Wrong song accepted") } catch {}
        for value in ["https://music.apple.com.attacker.example/cn/playlist/x/pl.abc", "https://music.apple.com@attacker.example/playlist/pl.abc", "file:///tmp/playlist", "https://music.apple.com/cn/album/x/123", "https://example.com/playlist/123"] {
            precondition(PlaylistSource.identify(value) == nil)
        }
        let suite = "MusicBridgeChecks.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var devices: [IPodDevice] = []
        let root = URL(fileURLWithPath: "/does-not-exist")
        let model = BridgeModel(root: root, preferences: preferences,
                                deviceProvider: { devices }, monitorDevices: false)
        defer { model.shutdown() }
        precondition(model.device == nil && !model.canImport && model.deviceStatus == "等待连接")
        precondition(model.quality == .hiRes)
        let wrapper = URL(string: "http://127.0.0.1:12340")!
        let urls = ["https://music.apple.com/cn/playlist/example/pl.abc"]
        let highArguments = DownloaderRunner.arguments(urls: urls, wrapperURL: wrapper, quality: model.quality)
        precondition(highArguments == ["--lite-server", wrapper.absoluteString, "--alac-max", "192000", "--json"] + urls)
        precondition(!highArguments.contains("--aac") && !highArguments.contains("--atmos"))
        model.quality = .lossless
        model.originalCover = false
        precondition(DownloaderRunner.arguments(urls: urls, wrapperURL: wrapper, quality: model.quality).contains("48000"))
        let restored = BridgeModel(root: root, preferences: preferences, deviceProvider: { [] }, monitorDevices: false)
        precondition(restored.quality == .lossless)
        precondition(!restored.originalCover)
        restored.shutdown()
        let volume = URL(fileURLWithPath: "/Volumes/Fixture", isDirectory: true)
        devices = [IPodDevice(name: "实际卷名", rootURL: volume, musicURL: volume.appendingPathComponent("Music"), writeState: .readOnly, isRockbox: true)]
        model.refreshDevice()
        precondition(model.device?.name == "实际卷名" && model.device?.rootURL == volume)
        precondition(model.deviceStatus == "设备只读" && !model.canImport)
        model.importMusic()
        precondition(!model.importing)
        devices = [IPodDevice(name: "实际卷名", rootURL: volume, musicURL: volume.appendingPathComponent("Music"), writeState: .unknown, isRockbox: true)]
        model.refreshDevice()
        precondition(model.deviceStatus == "权限待确认" && !model.canImport)
        devices = [IPodDevice(name: "实际卷名", rootURL: volume, musicURL: volume.appendingPathComponent("Music"), writeState: .writable, isRockbox: true)]
        model.refreshDevice()
        precondition(model.deviceStatus == "已挂载" && model.canImport)
        let phaseBeforeImport = model.phase
        model.importing = true
        model.startOrStop()
        model.stop()
        precondition(model.importing && !model.busy && model.phase == phaseBeforeImport)
        model.importing = false
        devices = []
        model.refreshDevice()
        precondition(model.device == nil && model.deviceStatus == "等待连接" && !model.canImport)
        model.source = "https://music.apple.com/cn/playlist/example/pl.abc"
        model.startOrStop()
        precondition(model.busy)
        model.stop()
        try await Task.sleep(for: .milliseconds(400))
        precondition(!model.busy && model.completed == 0 && model.phase == "已停止")
        precondition(model.completed == 0 && model.percent == 0 && !model.importing)
        try testPointerAndConfiguration()
        try testImportDestinations()
        if let fixture = ProcessInfo.processInfo.environment["MUSICBRIDGE_TEST_VOLUME"] {
            try testRockboxMountedFixture(URL(fileURLWithPath: fixture))
        }
        try testNativeImportSafety()
        try DeviceDiscoveryChecks.run()
        try IPodKnowledgeChecks.run()
        try NativeEngineChecks.run()
        try testDownloadProgressAndLibraryConfiguration()
        try testPlaylistPreparation()
        try await testReadinessCancellationAndOutput()
        print("PASS: device/import guards; quality/cover persistence; real launch arguments; cancellation; bounded motion/accessibility; config preservation; import path containment; stale readiness and EOF output")
    }

    static func testNativeImportSafety() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("MusicBridgeNative-\(UUID())")
        defer { try? manager.removeItem(at: base) }
        let volume = base.appendingPathComponent("Stock")
        let database = volume.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        try manager.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("mhbd synthetic database fixture".utf8)
        try contents.write(to: database)
        let detector = IPodImporter()
        let stock = detector.detectDevice(at: volume)!
        precondition(stock.hasNativeDatabase && !stock.isRockbox)
        precondition(!manager.fileExists(atPath: volume.appendingPathComponent("Music").path))
        precondition(stock.resolvedMode(.automatic) == .native && stock.resolvedMode(.rockbox) == nil)
        try manager.createDirectory(at: volume.appendingPathComponent(".rockbox"), withIntermediateDirectories: true)
        let dual = detector.detectDevice(at: volume)!
        precondition(dual.resolvedMode(.automatic) == .rockbox && dual.resolvedMode(.native) == .native)
        let rock = IPodDevice(name: "Rock", rootURL: volume, musicURL: volume.appendingPathComponent("Music"), writeState: .writable, isRockbox: true)
        precondition(rock.resolvedMode(.native) == nil && rock.resolvedMode(.rockbox) == .rockbox)
        let config = NativeIPodImporter.configuration(source: base.appendingPathComponent("含 空格/\"quoted\""))
        precondition(config.contains("cleanArtists = false") && config.contains("checkArtwork = false"))
        precondition(!config.contains("\\/"))
        let args = NativeIPodImporter.arguments(config: base.appendingPathComponent("config.toml"), device: dual, dryRun: true)
        precondition(args.contains("--dry-run") && args.contains("--skip-upgrades"))
        precondition(!args.contains("--delete") && !args.contains("--check-artwork") && !args.contains("--force-metadata"))
        let valid: [String: Any] = ["success": true, "dryRun": true,
            "plan": ["tracksToAdd": 2, "tracksExisting": 1, "tracksToTranscode": 0, "tracksToCopy": 2,
                     "tracksToRemove": 0, "tracksToUpdate": 0, "tracksToUpgrade": 0],
            "operations": [["type": "copy", "track": "a } quoted song"], ["type": "copy", "track": "b"]]]
        let encoded = try JSONSerialization.data(withJSONObject: valid, options: .prettyPrinted)
        let parsed = try NativeIPodImporter.parsePlan(encoded, sourceCount: 3)
        precondition(parsed == NativePlanSummary(additions: 2, existing: 1, conversions: 0))
        var hiddenTranscode = valid
        var enginePlan = valid["plan"] as! [String: Int]
        enginePlan["tracksToTranscode"] = 1; enginePlan["tracksToCopy"] = 1
        hiddenTranscode["plan"] = enginePlan
        do { _ = try NativeIPodImporter.parsePlan(JSONSerialization.data(withJSONObject: hiddenTranscode), sourceCount: 3); preconditionFailure("Engine re-encoding accepted") } catch {}
        for key in ["tracksToRemove", "tracksToUpdate", "tracksToUpgrade"] {
            var unsafe = valid
            var plan = valid["plan"] as! [String: Int]; plan[key] = 1; unsafe["plan"] = plan
            do { _ = try NativeIPodImporter.parsePlan(JSONSerialization.data(withJSONObject: unsafe), sourceCount: 3); preconditionFailure("Unsafe plan accepted") }
            catch {}
        }
        do { _ = try NativeIPodImporter.parsePlan(encoded, sourceCount: 4); preconditionFailure("Missing source accepted") } catch {}
        do { _ = try NativeIPodImporter.parsePlan(Data("{} trailing".utf8), sourceCount: 3); preconditionFailure("Invalid output accepted") } catch {}
        let success = Data("{\"success\":true,\"dryRun\":false,\"result\":{\"completed\":2,\"failed\":0}}".utf8)
        let completed = try NativeIPodImporter.parseResult(success, exitStatus: 0)
        precondition(completed == 2)
        do { _ = try NativeIPodImporter.parseResult(success, exitStatus: 1); preconditionFailure("Failed process accepted") } catch {}
        let failure = Data("{\"success\":false,\"dryRun\":false,\"result\":{\"completed\":1,\"failed\":1}}".utf8)
        do { _ = try NativeIPodImporter.parseResult(failure + Data("\n".utf8) + success, exitStatus: 0); preconditionFailure("Partial failure accepted") } catch {}
        // Even a directory resembling an iPod cannot pass the actual-volume identity guard.
        let engine = NativeIPodImporter(root: base)
        let fixturePlan = NativeImportPlan(id: UUID(), device: stock, engine: base.appendingPathComponent("unused-engine"),
            workspace: base, sourceCount: 0, missing: 0,
            summary: NativePlanSummary(additions: 0, existing: 0, conversions: 0), databaseFiles: [:], stagedFiles: [:])
        do { _ = try engine.execute(fixturePlan, progress: { _ in }); preconditionFailure("Non-volume accepted") }
        catch NativeImportError.invalidDevice {}
        let finalContents = try Data(contentsOf: database)
        precondition(finalContents == contents)
        print("PASS: stock detection without Music/; dual-system routing; additive-only plans; malformed and partial results rejected; fixture database unchanged")
    }

    static func testPlaylistPreparation() throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("MusicBridgePlaylist-\(UUID())")
        defer { try? manager.removeItem(at: base) }
        let downloads = base.appendingPathComponent("AM-DL downloads")
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        func run(_ executable: String, _ args: [String]) throws -> Data {
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/" + executable)
            task.arguments = args
            let pipe = Pipe(); task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
            try task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
            precondition(task.terminationStatus == 0); return data
        }
        let cover = base.appendingPathComponent("cover.jpg")
        _ = try run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "color=c=blue:s=32x32", "-frames:v", "1", cover.path])
        for index in 1...3 {
            _ = try run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1",
                                   "-c:a", "alac", "-metadata", "title=歌曲\(index)", "-metadata", "artist=歌手\(index)",
                                   "-metadata", "album=原专辑\(index)", downloads.appendingPathComponent("\(index).m4a").path])
        }
        let withCover = downloads.appendingPathComponent("covered.m4a")
        _ = try run("ffmpeg", ["-v", "error", "-i", downloads.appendingPathComponent("2.m4a").path, "-i", cover.path,
                               "-map", "0:a", "-map", "1:v", "-c", "copy", "-disposition:v", "attached_pic", withCover.path])
        try manager.removeItem(at: downloads.appendingPathComponent("2.m4a"))
        try manager.moveItem(at: withCover, to: downloads.appendingPathComponent("2.m4a"))
        let selection = PlaylistSelection(id: "123", name: "测试/歌单", sourceURL: URL(string: "https://music.163.com/playlist?id=123")!,
                                         coverURL: URL(string: "https://p1.music.126.net/cover.jpg")!,
                                         tracks: [PlaylistSong(title: "歌曲2", artist: "歌手2"), PlaylistSong(title: "歌曲1", artist: "歌手1"),
                                                  PlaylistSong(title: "尚未下载", artist: "歌手4")])
        let library = PlaylistLibrary(root: base)
        try library.save(selection)
        precondition(library.load()?.name == selection.name)
        precondition(!PlaylistLibrary.folderName(selection).contains("/"))
        let prepared = try library.prepare(selection, coverData: Data(contentsOf: cover)) { _, _, _ in }
        precondition(prepared.files.count == 2 && prepared.originals.count == 2 && prepared.missing == 1)
        let reused = try library.prepare(selection, coverData: Data(contentsOf: cover)) { _, _, _ in }
        precondition(reused.files.map(\.url) == prepared.files.map(\.url))
        let first = try run("ffprobe", ["-v", "error", "-show_entries", "format_tags:stream=codec_name", "-of", "json", prepared.files[0].url.path])
        let object = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        let tags = (object["format"] as! [String: Any])["tags"] as! [String: String]
        precondition(tags["album"] == "原专辑2")
        var singleArtist = selection
        singleArtist.tracks = [PlaylistSong(title: "甲", artist: "陈奕迅"), PlaylistSong(title: "乙", artist: "陈奕迅 & eason and the duo band")]
        precondition(PlaylistLibrary.displayAlbumArtist(for: singleArtist) == "陈奕迅")
        precondition(tags["title"] == "歌曲2" && tags["artist"] == "歌手2")
        let streams = object["streams"] as! [[String: Any]]
        precondition(streams.contains { $0["codec_name"] as? String == "alac" })
        precondition(manager.fileExists(atPath: prepared.files[0].url.deletingLastPathComponent().appendingPathComponent("cover.jpg").path))
        precondition(!manager.fileExists(atPath: prepared.files[1].url.deletingLastPathComponent().appendingPathComponent("cover.jpg").path))
        let preparedBytes = try Data(contentsOf: prepared.files[0].url)
        let sourceBytes = try Data(contentsOf: downloads.appendingPathComponent("2.m4a"))
        precondition(preparedBytes == sourceBytes)
        let original = try run("ffprobe", ["-v", "error", "-show_entries", "format_tags=album", "-of", "json", downloads.appendingPathComponent("2.m4a").path])
        precondition(String(decoding: original, as: UTF8.self).contains("原专辑2"))
        precondition(!PlaylistLibrary.matches(PlaylistSong(title: "歌曲1 (Live)", artist: "歌手1"), tags: ["title": "歌曲1", "artist": "歌手1"]))
        precondition(AppleMusicCatalogClient.isLiveVersion("歌曲 (2007 Live)"))
        precondition(!AppleMusicCatalogClient.isLiveVersion("Livewire"))
        let dottedAlbum = downloads.appendingPathComponent("...3mm")
        try manager.createDirectory(at: dottedAlbum, withIntermediateDirectories: true)
        try manager.moveItem(at: downloads.appendingPathComponent("3.m4a"), to: dottedAlbum.appendingPathComponent("3.m4a"))
        try Data("metadata".utf8).write(to: dottedAlbum.appendingPathComponent("._3.m4a"))
        precondition(IPodImporter().audioFiles(in: base).count == 3)
        _ = try run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1",
                               "-c:a", "flac", "-metadata", "title=FLAC歌曲", "-metadata", "artist=歌手", downloads.appendingPathComponent("4.flac").path])
        var flacSelection = selection
        flacSelection.tracks = [PlaylistSong(title: "FLAC歌曲", artist: "歌手")]
        let flacPrepared = try library.prepare(flacSelection, coverData: Data(contentsOf: cover)) { _, _, _ in }
        precondition(flacPrepared.files.first?.url.pathExtension == "flac")
        let flacProbe = try run("ffprobe", ["-v", "error", "-show_entries", "stream=codec_name", "-of", "json", flacPrepared.files[0].url.path])
        precondition(String(decoding: flacProbe, as: UTF8.self).contains("flac"))
        flacSelection.tracks.append(PlaylistSong(title: "FLAC歌曲", artist: "歌手"))
        let duplicate = try library.prepare(flacSelection, coverData: Data(contentsOf: cover)) { _, _, _ in }
        precondition(duplicate.files.count == 2 && duplicate.files[0].url != duplicate.files[1].url)
        let withoutCover = try library.prepare(flacSelection, coverData: Data()) { _, _, _ in }
        precondition(withoutCover.files.count == 2 && !manager.fileExists(atPath: withoutCover.files[0].url.deletingLastPathComponent().appendingPathComponent("cover.jpg").path))
        print("PASS: playlist membership, order, per-track artwork and original audio preservation; Live version guard")
    }

    static func testDownloadProgressAndLibraryConfiguration() throws {
        let original = "# preserve theme\nvolume: -25\ntagcache_autoupdate: off\ndatabase scan paths: /Podcasts\n"
        let configured = IPodImporter.libraryConfiguration(original)
        precondition(configured.contains("volume: -25\n"))
        precondition(configured.contains("tagcache_autoupdate: on\n"))
        precondition(configured.contains("database scan paths: /Podcasts:/Music\n"))
        precondition(IPodImporter.libraryConfiguration(configured) == configured)
        precondition(IPodImporter.libraryConfiguration("").contains("database scan paths: /\n"))
        let ioError = NSError(domain: NSPOSIXErrorDomain, code: 5)
        precondition(IPodImporter.isDeviceIOError(ioError))
        precondition(IPodImporter.isDeviceIOError(NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSUnderlyingErrorKey: ioError])))
        precondition(!IPodImporter.isDeviceIOError(NSError(domain: NSPOSIXErrorDomain, code: 2)))
        for name in ["database_0.tcd", "database_12.tcd", "database_idx.tcd", "database_state.tcd", "database_tmp.tcd"] {
            precondition(IPodImporter.isDatabaseIndexName(name))
        }
        for name in ["database.ignore", "database_changelog.txt", "config.cfg", "song.m4a", "../database_idx.tcd", "database_other.tcd"] {
            precondition(!IPodImporter.isDatabaseIndexName(name))
        }
        let pictureFlow = "zoom: 100\r\ncache version: 5\r\nlast album: 8\r\nart cache pos: 9\r\nart cache inspected: 9\r\n"
        let rebuilt = IPodImporter.pictureFlowRebuildConfiguration(pictureFlow)
        precondition(rebuilt.contains("zoom: 100\r\n") && rebuilt.contains("cache version: 0\r\n"))
        precondition(rebuilt.contains("last album: 0\r\n") && rebuilt.contains("art cache inspected: 0\r\n"))
        precondition(IPodImporter.pictureFlowRebuildConfiguration(rebuilt) == rebuilt)

        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("MusicBridgeProgress-\(UUID())")
        defer { try? manager.removeItem(at: base) }
        let downloads = base.appendingPathComponent("AM-DL downloads")
        try manager.createDirectory(at: downloads, withIntermediateDirectories: true)
        let service = IPodImporter()
        let baseline = service.snapshotAudioFiles(in: base)
        let partial = downloads.appendingPathComponent("unfinished.m4a")
        try Data("incomplete audio".utf8).write(to: partial)
        let song = downloads.appendingPathComponent("finished.m4a")
        let encoder = Process()
        encoder.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        encoder.arguments = ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1", "-c:a", "alac", song.path]
        try encoder.run()
        encoder.waitUntilExit()
        precondition(encoder.terminationStatus == 0)
        let first = service.downloadProgress(in: base, comparedTo: baseline, lastScan: [:], verified: [:])
        precondition(first.verified.isEmpty)
        let second = service.downloadProgress(in: base, comparedTo: baseline, lastScan: first.current, verified: first.verified)
        precondition(second.verified.count == 1 && second.verified.keys.first?.lastPathComponent == "finished.m4a")
        try manager.removeItem(at: song)
        let third = service.downloadProgress(in: base, comparedTo: baseline, lastScan: second.current, verified: second.verified)
        precondition(third.verified.isEmpty)
        print("PASS: live completed count excludes partial audio; removed outputs disappear; Rockbox settings preserve user values and are idempotent")
    }

    static func testPointerAndConfiguration() throws {
        let zero = SurfacePointer.normalized(location: CGPoint(x: CGFloat.nan, y: 10), size: CGSize(width: 100, height: 100))
        precondition(zero == SurfacePointer())
        precondition(SurfacePointer.normalized(location: .zero, size: .zero) == SurfacePointer())
        let pointer = SurfacePointer.normalized(location: CGPoint(x: 900, y: -900), size: CGSize(width: 100, height: 100))
        precondition(pointer == SurfacePointer(x: 1, y: -1))
        let offset = pointer.offset(hovered: true, reducedMotion: false, active: true, editing: false)
        precondition(abs(offset.width) <= 1.4 && abs(offset.height) <= 3)
        precondition(pointer.offset(hovered: true, reducedMotion: true, active: true, editing: false) == .zero)
        precondition(pointer.offset(hovered: true, reducedMotion: false, active: false, editing: false) == .zero)
        precondition(pointer.offset(hovered: true, reducedMotion: false, active: true, editing: true) == .zero)
        let configuration = "name: unchanged\nembed-cover: true\nnext-option: unchanged\n"
        precondition(DownloadConfiguration.settingCover(false, in: configuration) == "name: unchanged\nembed-cover: false\nnext-option: unchanged\n")
        precondition(DownloadConfiguration.settingCover(true, in: "name: unchanged") == "name: unchanged\nembed-cover: true\n")
        var buffer = OutputLineBuffer()
        precondition(buffer.append(Data("one\r\ntwo\rpar".utf8)) == ["one", "two"])
        precondition(buffer.append(Data("tial".utf8), endOfFile: true) == ["partial"])
        precondition(buffer.append(Data(), endOfFile: true).isEmpty)
        var longLine = OutputLineBuffer()
        precondition(longLine.append(Data(repeating: 65, count: 100_000)).isEmpty)
        precondition(longLine.append(Data(), endOfFile: true).first?.count == 65_536)
    }

    static func testImportDestinations() throws {
        precondition(IPodImporter.rockboxFormatIssue(extension: "m4a", codec: "alac") == nil)
        precondition(IPodImporter.rockboxFormatIssue(extension: "M4A", codec: "aac") == nil)
        precondition(IPodImporter.rockboxFormatIssue(extension: "flac", codec: "flac") == nil)
        precondition(IPodImporter.rockboxFormatIssue(extension: "m4a", codec: "flac") != nil)
        precondition(IPodImporter.rockboxFormatIssue(extension: "flac", codec: nil) != nil)
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("MusicBridgeImportChecks-\(UUID())")
        defer { try? manager.removeItem(at: base) }
        let source = base.appendingPathComponent("Downloads")
        let volume = base.appendingPathComponent("Device")
        let music = volume.appendingPathComponent("Music")
        let outside = base.appendingPathComponent("Outside")
        for directory in [source, music, outside] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let device = IPodDevice(name: "Fixture", rootURL: volume, musicURL: music, writeState: .writable, isRockbox: true)
        let service = IPodImporter()
        precondition(service.safeDestination(for: source.appendingPathComponent("album/song.m4a"), sourceRoot: source, device: device) != nil)
        precondition(service.safeDestination(for: outside.appendingPathComponent("song.m4a"), sourceRoot: source, device: device) == nil)
        try manager.createSymbolicLink(at: music.appendingPathComponent("escaped"), withDestinationURL: outside)
        precondition(service.safeDestination(for: source.appendingPathComponent("escaped/song.m4a"), sourceRoot: source, device: device) == nil)
        try manager.createSymbolicLink(at: music.appendingPathComponent("dangling"), withDestinationURL: outside.appendingPathComponent("missing"))
        precondition(service.safeDestination(for: source.appendingPathComponent("dangling/song.m4a"), sourceRoot: source, device: device) == nil)
        try manager.createSymbolicLink(atPath: music.appendingPathComponent("loop").path, withDestinationPath: "loop")
        precondition(service.safeDestination(for: source.appendingPathComponent("loop/song.m4a"), sourceRoot: source, device: device) == nil)
        try manager.createSymbolicLink(at: source.appendingPathComponent("outside-source"), withDestinationURL: outside)
        precondition(service.safeDestination(for: source.appendingPathComponent("outside-source/song.m4a"), sourceRoot: source, device: device) == nil)
        let report = service.importFiles([(source.appendingPathComponent("song.m4a"), source)], to: device)
        precondition(report.imported == 0 && !report.messages.isEmpty)
        precondition(!manager.fileExists(atPath: music.appendingPathComponent("song.m4a").path))
    }

    static func testRockboxMountedFixture(_ volume: URL) throws {
        let manager = FileManager.default
        precondition(manager.fileExists(atPath: volume.appendingPathComponent(".musicbridge-test-fixture").path))
        let music = volume.appendingPathComponent("Music"), rockbox = volume.appendingPathComponent(".rockbox")
        try manager.createDirectory(at: music, withIntermediateDirectories: true)
        try manager.createDirectory(at: rockbox, withIntermediateDirectories: true)
        let config = rockbox.appendingPathComponent("config.cfg")
        try Data("volume: -25\n".utf8).write(to: config)
        let base = manager.temporaryDirectory.appendingPathComponent("MusicBridgeRockbox-\(UUID())")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let song = base.appendingPathComponent("测试.flac")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "0.1", "-c:a", "flac", song.path]
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        let uuid = try volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        let device = IPodDevice(name: "Temporary fixture", rootURL: volume, musicURL: music, writeState: .writable, isRockbox: true, volumeIdentifier: uuid)
        let service = IPodImporter()
        let files = [(url: song, root: base)]
        let stale = try service.preview(files, device: device, playlistName: "测试", playlistID: "123", missing: 0)
        let originalAudio = try Data(contentsOf: song)
        try Data("changed".utf8).write(to: song)
        do { try service.validatePreview(stale); preconditionFailure("Changed source accepted") } catch {}
        try originalAudio.write(to: song)
        let preview = try service.preview(files, device: device, playlistName: "测试", playlistID: "123", missing: 0)
        precondition(preview.ready.count == 1 && preview.ready[0].spec?.codec == "flac")
        do { try service.validatePreview(preview) }
        catch { throw NSError(domain: "RockboxFixture.initialValidation", code: 1, userInfo: [NSUnderlyingErrorKey: error]) }
        let report = service.importFiles(files, to: device, expectedSignatures: [song: preview.ready[0].signature!], playlistID: "123", playlistName: "多歌手")
        precondition(report.imported == 1 && report.failedFiles == 0 && !report.interrupted)
        let playlist = try String(contentsOf: music.appendingPathComponent("多歌手-123.m3u8"), encoding: .utf8)
        precondition(playlist == "#EXTM3U\n/Music/测试.flac\n")
        let retainedConfig = try Data(contentsOf: config)
        precondition(retainedConfig == Data("volume: -25\n".utf8))
        let repeated = try service.preview(files, device: device, playlistName: "测试", playlistID: "123", missing: 0)
        precondition(repeated.ready.count == 1 && repeated.items[0].status.contains("内容一致"))
        let repeatReport = service.importFiles(files, to: device, expectedSignatures: [song: repeated.ready[0].signature!], playlistID: "123", playlistName: "多歌手")
        precondition(repeatReport.alreadyPresent == 1 && repeatReport.libraryInstruction?.contains("多歌手-123.m3u8") == true)
        let second = base.appendingPathComponent("另一首.flac")
        try manager.copyItem(at: song, to: second)
        let secondFiles = [(url: second, root: base)]
        let secondPreview = try service.preview(secondFiles, device: device, playlistName: "测试", playlistID: "123", missing: 0)
        let collision = service.importFiles(secondFiles, to: device, expectedSignatures: [second: secondPreview.ready[0].signature!], playlistID: "123", playlistName: "多歌手")
        precondition(collision.imported == 1 && collision.libraryInstruction?.contains("多歌手-123-") == true)
        let retainedPlaylist = try String(contentsOf: music.appendingPathComponent("多歌手-123.m3u8"), encoding: .utf8)
        precondition(retainedPlaylist == playlist)
        let third = base.appendingPathComponent("歌手甲-重复.flac")
        try manager.copyItem(at: song, to: third)
        let mixed = [(url: second, root: base), (url: song, root: base), (url: third, root: base)]
        let mixedPreview = try service.preview(mixed, device: device, playlistName: "不同歌手的歌单", playlistID: "456", missing: 0)
        precondition(mixedPreview.ready.count == 3)
        let signatures = Dictionary(uniqueKeysWithValues: mixedPreview.ready.map { ($0.url, $0.signature!) })
        let mixedReport = service.importFiles(mixed, to: device, expectedSignatures: signatures, playlistID: "456")
        precondition(mixedReport.imported == 1 && mixedReport.alreadyPresent == 2)
        let mixedPlaylist = try String(contentsOf: music.appendingPathComponent("MusicBridge-456.m3u8"), encoding: .utf8)
        precondition(mixedPlaylist == "#EXTM3U\n/Music/另一首.flac\n/Music/测试.flac\n/Music/歌手甲-重复.flac\n")
        print("PASS: Rockbox preview, mounted copy, M3U8 order, preserved config, repeated import and stale source guard")
    }

    @MainActor
    static func testReadinessCancellationAndOutput() async throws {
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("MusicBridgeRunnerChecks-\(UUID())")
        try manager.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        try "embed-cover: true\n".write(to: base.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let first = base.appendingPathComponent("first")
        let second = base.appendingPathComponent("second")
        try "#!/bin/sh\nprintf first-launched > first-marker\n".write(to: first, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nprintf 'second-output-without-newline'\n".write(to: second, atomically: true, encoding: .utf8)
        for url in [first, second] { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
        var probes: [(Result<Void, Error>) -> Void] = []
        let runner = DownloaderRunner(statusProbe: { _, completion in probes.append(completion) })
        defer { runner.stop() }
        var output: [String] = []
        runner.onOutput = { output.append($0) }
        let wrapper = URL(string: "http://127.0.0.1:12340")!
        runner.start(binaryPath: first.path, workingDirectory: base.path, urls: [], wrapperLauncherPath: nil,
                     wrapperURL: wrapper, quality: .hiRes, completion: { _ in })
        precondition(probes.count == 1)
        runner.stop()
        runner.start(binaryPath: second.path, workingDirectory: base.path, urls: [], wrapperLauncherPath: nil,
                     wrapperURL: wrapper, quality: .hiRes, completion: { _ in })
        precondition(probes.count == 2)
        probes[0](.success(()))
        probes[1](.success(()))
        try await Task.sleep(for: .milliseconds(400))
        precondition(!manager.fileExists(atPath: base.appendingPathComponent("first-marker").path))
        precondition(output.contains("second-output-without-newline"))
    }
}
