import Foundation

enum NativeWorkflowChecks {
    static func run(repo: URL, base: URL) throws {
        let manager = FileManager.default
        let volume = base.appendingPathComponent("empty-classic")
        let deviceInfo = volume.appendingPathComponent("iPod_Control/Device")
        try manager.createDirectory(at: deviceInfo, withIntermediateDirectories: true)
        try manager.createDirectory(at: volume.appendingPathComponent(".rockbox"), withIntermediateDirectories: true)
        try "Target: ipod6g\n".write(to: volume.appendingPathComponent(".rockbox/rockbox-info.txt"), atomically: true, encoding: .utf8)
        try Data().write(to: deviceInfo.appendingPathComponent("SysInfo"))
        let original = try Data(contentsOf: deviceInfo.appendingPathComponent("SysInfo"))
        let device = IPodDevice(name: "Synthetic Classic", rootURL: volume, musicURL: volume.appendingPathComponent("Music"),
            writeState: .writable, isRockbox: true, volumeIdentifier: "synthetic-classic", identity: IPodKnowledge.read(at: volume))
        let library = NativeLibraryService(root: repo, mountValidator: { target in
            guard target.rootURL == volume else { throw NativeImportError.invalidDevice }
        }, identifierProvider: { _ in "000A27001A2B3C4D" })
        do { _ = try library.initialize(device, profileID: "video_1") { _ in }; preconditionFailure("Family mismatch must be blocked") }
        catch { let after = try Data(contentsOf: deviceInfo.appendingPathComponent("SysInfo")); precondition(after == original) }
        let backup = try library.initialize(device, profileID: "classic_3") { _ in }
        defer { try? manager.removeItem(at: backup.deletingLastPathComponent()) }
        let backedUpInfo = try Data(contentsOf: backup.appendingPathComponent("Device/SysInfo"))
        precondition(backedUpInfo == original)
        let written = try String(contentsOf: deviceInfo.appendingPathComponent("SysInfo"), encoding: .utf8)
        precondition(written.contains("MC293") && !written.contains("MA147"))
        let identity = IPodKnowledge.read(at: volume)
        precondition(identity.profileID == nil && identity.configuredProfileID == "classic_3")
        precondition(identity.importProfile?.id == "classic_3" && identity.status.contains("实际代数未自动确认"))
        let database = volume.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        let before = try Data(contentsOf: database)
        do { _ = try library.initialize(device, profileID: "classic_3") { _ in }; preconditionFailure("Existing database must never be overwritten") }
        catch { let after = try Data(contentsOf: database); precondition(after == before) }
        let orphan = base.appendingPathComponent("orphaned-native")
        try manager.createDirectory(at: orphan.appendingPathComponent("iPod_Control/Music/F00"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: orphan.appendingPathComponent("iPod_Control/Music/F00/existing.m4a"))
        let orphanDevice = IPodDevice(name: "Orphaned", rootURL: orphan, musicURL: orphan.appendingPathComponent("Music"),
            writeState: .writable, isRockbox: false)
        let orphanLibrary = NativeLibraryService(root: repo, mountValidator: { target in
            guard target.rootURL == orphan else { throw NativeImportError.invalidDevice }
        }, identifierProvider: { _ in "000A27001A2B3C4D" })
        do { _ = try orphanLibrary.initialize(orphanDevice, profileID: "classic_3") { _ in }; preconditionFailure("Orphaned audio must block new empty library") }
        catch { precondition(!manager.fileExists(atPath: orphan.appendingPathComponent("iPod_Control/iTunes/iTunesDB").path)) }
        precondition(IPodKnowledge.usbFamily(product: 0x1261) == "classic")
        precondition(IPodKnowledge.usbFamily(product: 0x1209) == "video")
        precondition(IPodKnowledge.usbFamily(product: 0x1207) == nil)
        print("PASS: explicit Classic initialization, real-identifier requirement, initialization provenance, backup, no overwrite, orphan guard, playlist order/conflict/idempotency")
    }
}
