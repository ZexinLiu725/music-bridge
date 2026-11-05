import Foundation

enum DeviceDiscoveryChecks {
    @MainActor
    static func run() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("DeviceDiscovery-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let volume = root.appendingPathComponent("generic-usb")
        let rockbox = volume.appendingPathComponent(".rockbox")
        try manager.createDirectory(at: rockbox, withIntermediateDirectories: true)
        let detector = IPodImporter()
        precondition(detector.detectDevice(at: volume) == nil)
        try "Target: sansaclip\n".write(to: rockbox.appendingPathComponent("rockbox-info.txt"), atomically: true, encoding: .utf8)
        precondition(detector.detectDevice(at: volume) == nil)
        try "Target: ipod6g\n".write(to: rockbox.appendingPathComponent("rockbox-info.txt"), atomically: true, encoding: .utf8)
        let filesOnly = detector.detectDevice(at: volume)!
        precondition(filesOnly.isRockbox && filesOnly.identity.profileID == nil && !filesOnly.identity.usbIPodConfirmed)
        let video = IPodKnowledge.identify(sysInfo: nil, extended: nil, rockboxInfo: "Target: ipodvideo")
        precondition(video.familyHint?.contains("Video") == true && video.importProfile == nil)
        let mini = IPodKnowledge.identify(sysInfo: nil, extended: nil, rockboxInfo: "Target: ipodmini2g")
        precondition(mini.nativeFamilyUnsupported && mini.importProfile == nil && !mini.allowsManualProfile("classic_3"))
        let db = volume.appendingPathComponent("iPod_Control/iTunes/iTunesDB")
        try manager.createDirectory(at: db.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid database".utf8).write(to: db)
        let corrupt = detector.detectDevice(at: volume)!
        precondition(corrupt.nativeDatabaseUnreadable && !corrupt.hasNativeDatabase)
        try manager.removeItem(at: db)
        try Data([1,2,3]).write(to: db.deletingLastPathComponent().appendingPathComponent("iTunesCDB"))
        let compressed = detector.detectDevice(at: volume)!
        precondition(compressed.hasCompressedNativeDatabase && !compressed.hasNativeDatabase)
        let suite = "DeviceDiscovery.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let blocked = BridgeModel(root: root, preferences: preferences, deviceProvider: { [compressed] }, monitorDevices: false)
        defer { blocked.shutdown() }
        blocked.importMode = .native
        precondition(!blocked.needsNativeInitialization && blocked.resolvedImportMode == nil)
        let a = IPodDevice(name: "同名设备", rootURL: root.appendingPathComponent("A"), musicURL: root.appendingPathComponent("A/Music"),
            writeState: .writable, isRockbox: true, volumeIdentifier: "A", hasNativeDatabase: true)
        let b = IPodDevice(name: "同名设备", rootURL: root.appendingPathComponent("B"), musicURL: root.appendingPathComponent("B/Music"),
            writeState: .writable, isRockbox: true, volumeIdentifier: "B", hasNativeDatabase: true)
        var devices = [a,b]
        let model = BridgeModel(root: root, preferences: preferences, deviceProvider: { devices }, monitorDevices: false)
        defer { model.shutdown() }
        precondition(model.device == nil && model.deviceStatus == "请选择设备")
        model.selectDevice("A"); model.importMode = .native
        devices = [b,a]; model.refreshDevice()
        precondition(model.device?.volumeIdentifier == "A" && model.importMode == .native)
        devices = [b]; model.refreshDevice()
        precondition(model.device == nil && !model.canImport)
        model.selectDevice("B")
        precondition(model.device?.volumeIdentifier == "B")
        var metricsChanged = b; metricsChanged.availableBytes = 12345
        precondition(metricsChanged.matchesImportTarget(b))
        devices = [metricsChanged]; model.refreshDevice()
        precondition(model.device?.availableBytes == 12345)
        var replacement = b; replacement.volumeIdentifier = "different-volume"
        devices = [replacement]; model.refreshDevice()
        precondition(model.device == nil && !model.canImport)
        print("PASS: non-iPod USB filtering, file-vs-hardware evidence, corrupt/compressed library guards, explicit multi-device selection, UUID replacement, capacity-independent import identity")
    }
}
