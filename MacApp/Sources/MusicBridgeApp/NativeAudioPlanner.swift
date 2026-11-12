import Foundation

struct NativeAudioSpec: Sendable, Equatable {
    let codec: String
    let bits: Int?
    let rate: Int
    let channels: Int
    var isLossless: Bool { ["alac", "flac"].contains(codec) || codec.hasPrefix("pcm_") }
    var description: String {
        "\(codec.uppercased()) · \(bits.map { "\($0)bit / " } ?? "")\(Double(rate) / 1000)kHz · \(channels) 声道"
    }
}

enum NativeAudioDisposition: Sendable { case direct, sameSpecALAC, deferred, unresolved }

struct NativeAudioItem: Sendable, Identifiable {
    var id: String { url.path }
    let url: URL
    let sourceRoot: URL
    let signature: FileSignature
    let spec: NativeAudioSpec?
    let disposition: NativeAudioDisposition
    let reason: String
    let target: NativeAudioSpec?
}

struct NativeAudioAssessment: Sendable {
    var items: [NativeAudioItem]
    var ready: [NativeAudioItem] { items.filter { $0.disposition == .direct || $0.disposition == .sameSpecALAC } }
    var pending: [NativeAudioItem] { items.filter { $0.disposition == .deferred } }
    var blocked: [NativeAudioItem] { items.filter { $0.disposition == .unresolved } }
    var sameSpecCount: Int { items.filter { $0.disposition == .sameSpecALAC }.count }
    var lossyCount: Int { ready.filter { $0.spec?.isLossless == false }.count }
}

enum NativeAudioError: LocalizedError {
    case unknownModel, missingTools, unreadable, conversionFailed, changed, peakUnknown
    var errorDescription: String? {
        switch self {
        case .unknownModel: return "具体机型尚未确认或未适配，已停止原生导入。请查看兼容详情；不会按容量猜测机型。"
        case .missingTools: return "音频处理需要 FFmpeg 与 ffprobe。"
        case .unreadable: return "无法确认音频编码、有效位深、采样率或声道，未导入。"
        case .conversionFailed: return "转换或输出规格检查失败，原文件保留，未导入这首歌。"
        case .changed: return "原文件已变化，请重新检查并生成导入计划。"
        case .peakUnknown: return "无法确认重采样后的峰值，未执行降规格转换。"
        }
    }
}

struct NativeAudioPlanner: Sendable {
    static func decision(spec: NativeAudioSpec, extension ext: String, profile: IPodProfile) -> (NativeAudioDisposition, String, NativeAudioSpec?) {
        guard profile.nativeWriterSupported else { return (.unresolved, "原生数据库版本未适配", nil) }
        guard spec.rate > 0, spec.channels > 0 else { return (.unresolved, "音频规格缺失", nil) }
        if !spec.isLossless {
            if ["mp3", "aac"].contains(spec.codec), ["mp3", "m4a", "mp4"].contains(ext),
               [32000, 44100, 48000].contains(spec.rate), spec.channels <= 2 {
                return (.direct, "原本为有损音源，原样导入，不重新编码", nil)
            }
            return (.unresolved, "有损编码或容器不在首版原样导入范围；不会转换后冒充无损", nil)
        }
        guard let bits = spec.bits, bits > 0 else { return (.unresolved, "有效位深未知", nil) }
        let covered = profile.losslessSpecifications.contains { $0.bits == bits && $0.rate == spec.rate && $0.channels == spec.channels }
        if covered {
            if spec.codec == "alac", ["m4a", "mp4"].contains(ext) { return (.direct, "同规格无损直接导入", nil) }
            return (.sameSpecALAC, "保持位深、采样率与声道，转换为 ALAC", nil)
        }
        guard spec.channels <= 2 else { return (.unresolved, "多声道需要另行混音，本版不自动下混", nil) }
        // Do not upsample low-rate material or increase bit depth to fit a preset.
        guard bits >= 16, spec.rate >= 44100 else { return (.unresolved, "知识库未覆盖该组合；不升频或补位深", nil) }
        let rates = profile.losslessSpecifications.map(\.rate).filter { $0 <= spec.rate }
        // Preserve a 44.1kHz-family source where possible; 48/96/192kHz uses 48kHz.
        let rate = spec.rate % 44100 == 0 && rates.contains(44100) ? 44100 : rates.max() ?? 44100
        let target = NativeAudioSpec(codec: "alac", bits: 16, rate: rate, channels: spec.channels)
        return (.deferred, "超出\(profile.name)当前导入目标规格；可选择降低规格，原文件保留", target)
    }

    func assess(_ files: [(url: URL, root: URL)], device: IPodDevice,
                progress: @Sendable (String) -> Void) throws -> NativeAudioAssessment {
        guard device.identity.permitsNativeImport, let profile = device.identity.importProfile else { throw NativeAudioError.unknownModel }
        var items: [NativeAudioItem] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let url = file.url.resolvingSymlinksInPath(), source = file.root.resolvingSymlinksInPath()
            guard url.path.hasPrefix(source.path + "/") else { throw PlaylistLibraryError.invalidPath }
            let stamp = try NativeAudioTools.signature(url)
            progress("检查音频规格 \(index + 1) / \(files.count)")
            do {
                let spec = try NativeAudioTools.probe(url)
                let (disposition, reason, target) = Self.decision(spec: spec, extension: url.pathExtension.lowercased(), profile: profile)
                items.append(.init(url: url, sourceRoot: source, signature: stamp, spec: spec, disposition: disposition, reason: reason, target: target))
            } catch NativeAudioError.missingTools { throw NativeAudioError.missingTools }
            catch {
                items.append(.init(url: url, sourceRoot: source, signature: stamp, spec: nil, disposition: .unresolved,
                                   reason: "音频无法读取或规格缺失", target: nil))
            }
        }
        return NativeAudioAssessment(items: items)
    }
}

enum NativeAudioTools {
    // A filter option can exist even when FFmpeg was built without libsoxr.
    // Exercise the engine instead of trusting the help text.
    static let usesSoxr: Bool = (try? run("ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono",
        "-t", "0.01", "-af", "aresample=44100:resampler=soxr:precision=28", "-f", "null", "-"])) != nil
    static var resamplerName: String { usesSoxr ? "soxr · 28bit 精度" : "FFmpeg SWR · 64 抽头滤波" }
    static var resamplerOptions: String {
        usesSoxr ? "resampler=soxr:precision=28" : "resampler=swr:filter_size=64:phase_shift=10:exact_rational=1:cutoff=0.97"
    }
    static func signature(_ url: URL) throws -> FileSignature {
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { throw NativeAudioError.unreadable }
        return FileSignature(size: UInt64(size), modificationDate: modified)
    }

    static func tool(_ name: String) throws -> URL {
        guard let path = ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].map({ $0 + name })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw NativeAudioError.missingTools }
        return URL(fileURLWithPath: path)
    }

    static func run(_ name: String, _ arguments: [String], stderr: Bool = false, timeout: TimeInterval = 1800) throws -> Data {
        let process = Process(); process.executableURL = try tool(name)
        process.arguments = (name == "ffmpeg" ? ["-nostdin", "-nostats"] : []) + arguments
        process.standardInput = FileHandle.nullDevice
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("musicbridge-audio-\(UUID()).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
        process.standardOutput = stderr ? FileHandle.nullDevice : handle
        process.standardError = stderr ? handle : FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled || Date() > deadline {
                process.terminate(); process.waitUntilExit(); throw NativeAudioError.conversionFailed
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, try signature(output).size < 8 * 1024 * 1024 else { throw NativeAudioError.conversionFailed }
        return try Data(contentsOf: output)
    }

    static func probe(_ url: URL) throws -> NativeAudioSpec {
        let data = try run("ffprobe", ["-v", "error", "-select_streams", "a:0", "-show_entries",
            "stream=codec_name,bits_per_raw_sample,bits_per_sample,sample_rate,channels", "-of", "json", url.path], timeout: 8)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = json["streams"] as? [[String: Any]], let audio = streams.first,
              let codec = audio["codec_name"] as? String else { throw NativeAudioError.unreadable }
        func number(_ key: String) -> Int? {
            if let v = audio[key] as? Int { return v }
            return (audio[key] as? String).flatMap(Int.init)
        }
        let raw = number("bits_per_raw_sample") ?? 0
        let stored = number("bits_per_sample") ?? 0
        guard let rate = number("sample_rate"), let channels = number("channels"), rate > 0, channels > 0 else { throw NativeAudioError.unreadable }
        return NativeAudioSpec(codec: codec, bits: raw > 0 ? raw : stored > 0 ? stored : nil, rate: rate, channels: channels)
    }

    static func decodeCheck(_ url: URL) throws {
        _ = try run("ffmpeg", ["-v", "error", "-xerror", "-i", url.path, "-map", "0:a:0", "-f", "null", "-"])
    }

    /// Returns the gain reduction applied to avoid clipping after resampling.
    static func convert(_ item: NativeAudioItem, to destination: URL, target: NativeAudioSpec) throws -> Double {
        guard let source = item.spec, source.isLossless, target.codec == "alac", target.bits == 16,
              target.channels == source.channels, target.rate <= source.rate,
              let sourceBits = source.bits, sourceBits >= 16 else { throw NativeAudioError.conversionFailed }
        guard try signature(item.url) == item.signature else { throw NativeAudioError.changed }
        let resamples = source.rate != target.rate
        let quantizes = sourceBits > 16 || resamples
        var gain = 0.0
        if resamples {
            let analysis = try run("ffmpeg", ["-v", "info", "-i", item.url.path, "-map", "0:a:0", "-af",
                "aresample=\(target.rate):\(resamplerOptions):osf=fltp,astats=metadata=0:reset=0", "-f", "null", "-"], stderr: true)
            let lines = (String(data: analysis, encoding: .utf8) ?? "").components(separatedBy: .newlines)
            let peaks = lines.compactMap { line -> Double? in
                guard let range = line.range(of: "Peak level dB: ") else { return nil }
                return Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
            }
            guard let peak = peaks.max(), !peak.isNaN else { throw NativeAudioError.peakUnknown }
            if peak > 0 { gain = peak + 0.01 }
        }
        var args = ["-v", "error", "-n", "-i", item.url.path, "-map", "0:a:0", "-map", "0:v?", "-map_metadata", "0",
                    "-c:a", "alac", "-sample_fmt", "s16p", "-c:v", "copy", "-disposition:v", "attached_pic"]
        if quantizes {
            var filter = resamples ? "aresample=\(target.rate):\(resamplerOptions):osf=fltp," : ""
            if gain > 0 { filter += "volume=-\(gain)dB," }
            filter += "aresample=osf=s16:dither_method=triangular"
            args += ["-af", filter]
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try run("ffmpeg", args + [destination.path])
        let actual = try probe(destination)
        guard actual == target, try signature(item.url) == item.signature else { throw NativeAudioError.conversionFailed }
        // Decode the entire generated audio, not just the container header.
        try decodeCheck(destination)
        return gain
    }
}
