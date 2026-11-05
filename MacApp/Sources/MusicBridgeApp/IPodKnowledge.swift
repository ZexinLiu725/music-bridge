import Foundation
import DiskArbitration
import IOKit

struct IPodProfile: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let modelCodes: [String]
    let nativeWriterSupported: Bool
    let source: String
    // Application import targets; do not present these as an Apple-published decoder maximum.
    var losslessSpecifications: [NativeAudioSpec] {
        guard nativeWriterSupported else { return [] }
        let rates = id == "classic_3" ? [44100, 48000] : [44100]
        return rates.flatMap { rate in [1, 2].map { NativeAudioSpec(codec: "alac", bits: 16, rate: rate, channels: $0) } }
    }
}

struct IPodIdentity: Sendable, Equatable {
    var profileID: String?
    var modelCode: String?
    var firmware: String?
    var evidence: [String] = []
    var conflict = false
    var familyHint: String?
    var usbEvidence: String?
    var userConfirmedProfileID: String?
    var configuredProfileID: String?
    var usbIPodConfirmed = false
    var rockboxTarget: String?
    var nativeFamilyUnsupported = false
    var profile: IPodProfile? { IPodKnowledge.profiles.first { $0.id == (profileID ?? userConfirmedProfileID ?? configuredProfileID) } }
    var importProfile: IPodProfile? {
        if conflict || nativeFamilyUnsupported { return nil }
        if let profile { return profile }
        // Default is a planning choice, never a fabricated detected identity.
        if familyHint?.contains("Video") == true { return nil }
        return IPodKnowledge.defaultImportProfile
    }
    var title: String { conflict ? "机型信息冲突" : (profileID == nil && userConfirmedProfileID == nil ? familyHint : profile?.name) ?? "具体机型待确认" }
    var permitsNativeImport: Bool { !conflict && importProfile?.nativeWriterSupported == true }
    var status: String {
        if conflict { return "信息冲突" }
        if configuredProfileID != nil && profileID == nil && userConfirmedProfileID == nil { return "初始化配置已记录 · 实际代数未自动确认" }
        if profile == nil { return importProfile == nil ? "实际机型待确认" : "实际机型待确认 · 默认按 Classic 3G 规划" }
        return profileID == nil ? "用户确认型号 · 未自动识别 / 未实机验证" : "型号代码已匹配 · 未实机验证"
    }
    func allowsManualProfile(_ id: String) -> Bool {
        guard !conflict, !nativeFamilyUnsupported, profileID == nil, IPodKnowledge.profiles.contains(where: { $0.id == id && $0.nativeWriterSupported }) else { return false }
        if familyHint?.contains("classic") == true { return id.hasPrefix("classic_") }
        if familyHint?.contains("Video") == true { return id.hasPrefix("video_") }
        return true
    }
    static let unknown = IPodIdentity()
}

/// Versioned, offline knowledge. Do not infer generation from capacity or A1238:
/// Apple reused A1238 across all Classic revisions.
enum IPodKnowledge {
    static let version = "2026.10.21.3"
    static let defaultImportProfileID = "classic_3"
    static let knownRockboxTargets: Set<String> = ["ipod1g2g", "ipod3g", "ipod4g", "ipodcolor", "ipodmini1g", "ipodmini2g", "ipodnano1g", "ipodnano2g", "ipodvideo", "ipod6g"]
    static var defaultImportProfile: IPodProfile { profiles.first { $0.id == defaultImportProfileID }! }
    static let identificationSource = "https://support.apple.com/en-us/103823"
    static let codeSource = "https://github.com/gtkpod/libgpod/blob/main/src/itdb_device.c"
    static let policyNote = "默认目标为 iPod classic 3G（2009）：ALAC 16bit / 44.1 或 48kHz，单/双声道。这是软件的导入目标；Apple 官方未列出独立 ALAC 音频的位深/采样率上限，尚未完成实体设备播放或 DAC 输出验证。其他规格在首轮结束后选择转换。"
    static func policyNote(for identity: IPodIdentity) -> String {
        guard let profile = identity.importProfile else { return "机型冲突或未适配，原生导入不可用。" }
        if profile.id == defaultImportProfileID { return policyNote }
        return "当前导入目标：\(profile.name)，ALAC 16bit / 44.1kHz、单/双声道。此配置不代表官方硬件上限；尚未完成实体设备验证。"
    }
    static let profiles: [IPodProfile] = [
        .init(id: "video_1", name: "iPod Video · 第 5 代", modelCodes: ["A002", "A146", "A003", "A147", "A452"], nativeWriterSupported: true, source: codeSource),
        .init(id: "video_2", name: "iPod Video · 第 5.5 代", modelCodes: ["A444", "A446", "A664", "A448", "A450"], nativeWriterSupported: true, source: codeSource),
        .init(id: "classic_1", name: "iPod classic · 2007", modelCodes: ["B029", "B147", "B145", "B150"], nativeWriterSupported: true, source: codeSource),
        .init(id: "classic_2", name: "iPod classic · 2008", modelCodes: ["B562", "B565"], nativeWriterSupported: true, source: codeSource),
        .init(id: "classic_3", name: "iPod classic 3G · 2009", modelCodes: ["C293", "C297"], nativeWriterSupported: true, source: codeSource),
        .init(id: "nano_6", name: "iPod nano · 第 6 代", modelCodes: ["C525", "C526", "C688", "C689", "C690", "C691", "C692", "C693", "C694", "C695", "C696", "C697", "C698", "C699"], nativeWriterSupported: false, source: codeSource)
    ]

    static func canonicalCode(_ value: String) -> String? {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Match exact part-code shape, optionally with Apple M prefix and region suffix.
        guard let range = code.range(of: "^(?:M)?([A-Z][0-9]{3})(?:[A-Z]{1,3}(?:/A)?)?$", options: .regularExpression) else { return nil }
        var stem = String(code[range])
        if stem.hasPrefix("M") { stem.removeFirst() }
        return String(stem.prefix(4))
    }

    static func identify(sysInfo: String?, extended: [String: Any]?, rockboxInfo: String?) -> IPodIdentity {
        var candidates: [String] = []
        var evidence: [String] = []
        var firmware: String?
        for line in (sysInfo ?? "").split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2 else { continue }
            if fields[0] == "ModelNumStr" {
                if let code = canonicalCode(fields[1]) { candidates.append(code); evidence.append("SysInfo 型号代码：" + code) }
            }
            if ["FirmwareVersion", "VisibleBuildID"].contains(fields[0]) { firmware = String(fields[1].prefix(40)) }
        }
        for key in ["ModelNumStr", "ModelNumber"] {
            if let raw = extended?[key] as? String, let code = canonicalCode(raw) {
                candidates.append(code); evidence.append("SysInfoExtended 型号代码：" + code)
            }
        }
        if let value = extended?["VisibleBuildID"] as? String { firmware = String(value.prefix(40)) }
        let unique = Set(candidates)
        let matches = profiles.filter { profile in unique.contains(where: { profile.modelCodes.contains($0) }) }
        var conflict = unique.count > 1
        let target = (rockboxInfo ?? "").split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Target:") })?
            .dropFirst("Target:".count).trimmingCharacters(in: .whitespaces)
        let knownTarget = target.flatMap { knownRockboxTargets.contains($0) ? $0 : nil }
        let hint = knownTarget.map { target in
            target == "ipod6g" ? "iPod classic（代数待确认）" : target == "ipodvideo" ? "iPod Video（代数待确认）" : "iPod · Rockbox 目标 " + target
        }
        if let knownTarget {
            evidence.append("Rockbox Target：" + knownTarget + "；仅为系统文件中的目标配置")
            if let profile = matches.first, (knownTarget == "ipod6g" && !profile.id.hasPrefix("classic_")) || (knownTarget == "ipodvideo" && !profile.id.hasPrefix("video_")) { conflict = true }
        }
        return IPodIdentity(profileID: conflict ? nil : matches.first?.id, modelCode: unique.sorted().first,
                            firmware: firmware, evidence: evidence, conflict: conflict, familyHint: hint,
                            rockboxTarget: knownTarget, nativeFamilyUnsupported: knownTarget.map { !["ipod6g", "ipodvideo"].contains($0) } ?? false)
    }

    static func read(at root: URL) -> IPodIdentity {
        let device = root.appendingPathComponent("iPod_Control/Device")
        func boundedData(_ file: URL) -> Data? {
            guard file.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1024 * 1024 else { return nil }
            return try? Data(contentsOf: file)
        }
        let info = boundedData(device.appendingPathComponent("SysInfo")).flatMap { String(data: $0, encoding: .utf8) }
        let extended = boundedData(device.appendingPathComponent("SysInfoExtended")).flatMap {
            (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
        }
        let rockbox = boundedData(root.appendingPathComponent(".rockbox/rockbox-info.txt")).flatMap { String(data: $0, encoding: .utf8) }
        var identity = identify(sysInfo: info, extended: extended, rockboxInfo: rockbox)
        if let data = boundedData(device.appendingPathComponent("MusicBridgeIdentity.json")),
           let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           !identity.conflict, marker["schema"] as? Int == 1, marker["originalProfileID"] is NSNull,
           marker["writtenModelCode"] as? String == identity.modelCode,
           let configured = marker["configuredProfileID"] as? String,
           profiles.contains(where: { $0.id == configured }) {
            // A model we wrote is configuration evidence, never fresh hardware identification.
            identity.profileID = nil; identity.modelCode = nil; identity.configuredProfileID = configured
            identity.evidence = ["设备型号记录由 Music Bridge 初始化时按用户选择写入；实际代数未自动确认"]
        }
        if let usb = usbIdentity(root) {
            identity.usbEvidence = String(format: "USB %04x:%04x（沿当前卷的设备链读取）", usb.vendor, usb.product)
            // USB product IDs identify at most a family here; never a Classic revision.
            let family = usb.vendor == 0x05ac ? usbFamily(product: usb.product) : nil
            identity.usbIPodConfirmed = family != nil
            if let family, let id = identity.profile?.id, !id.hasPrefix(family + "_") { identity.conflict = true }
            if let family, identity.profileID == nil, identity.familyHint == nil {
                identity.familyHint = family == "classic" ? "iPod classic（代数待确认）" : family == "video" ? "iPod Video（代数待确认）" : "iPod nano（代数待确认）"
            }
            if family == "nano" { identity.nativeFamilyUnsupported = true }
        }
        return identity
    }

    static func usbFamily(product: Int) -> String? {
        switch product { case 0x1261: return "classic"; case 0x1209: return "video"; case 0x1266: return "nano"; default: return nil }
    }

    static func hardwareIdentifier(at root: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, root as CFURL),
              let whole = DADiskCopyWholeDisk(disk) else { return nil }
        var node = DADiskCopyIOMedia(whole)
        guard node != 0 else { return nil }
        defer { if node != 0 { IOObjectRelease(node) } }
        for _ in 0..<24 {
            let vendor = IORegistryEntryCreateCFProperty(node, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
            if vendor?.intValue == 0x05ac,
               let value = IORegistryEntryCreateCFProperty(node, "USB Serial Number" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
               value.range(of: "^[A-Fa-f0-9]{16}$", options: .regularExpression) != nil { return value }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(node); node = parent
        }
        return nil
    }

    private static func usbIdentity(_ root: URL) -> (vendor: Int, product: Int)? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, root as CFURL),
              let whole = DADiskCopyWholeDisk(disk) else { return nil }
        var node = DADiskCopyIOMedia(whole)
        guard node != 0 else { return nil }
        defer { if node != 0 { IOObjectRelease(node) } }
        for _ in 0..<24 {
            func number(_ key: String) -> Int? {
                (IORegistryEntryCreateCFProperty(node, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            }
            if let vendor = number("idVendor"), let product = number("idProduct") { return (vendor, product) }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(node); node = parent
        }
        return nil
    }
}
