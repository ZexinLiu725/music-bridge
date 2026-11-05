import Foundation

enum IPodKnowledgeChecks {
    @MainActor
    static func run() throws {
        let classic = IPodKnowledge.identify(sysInfo: "ModelNumStr: MC293LL/A\nVisibleBuildID: 2.0.4", extended: nil, rockboxInfo: nil)
        precondition(classic.profileID == "classic_3" && classic.permitsNativeImport && classic.firmware == "2.0.4")
        let conflict = IPodKnowledge.identify(sysInfo: "ModelNumStr: MB029", extended: ["ModelNumStr": "MC293"], rockboxInfo: nil)
        precondition(conflict.conflict && !conflict.permitsNativeImport)
        let unknown = IPodKnowledge.identify(sysInfo: "ModelNumStr: A1238", extended: nil, rockboxInfo: "Target: ipod6g")
        precondition(unknown.profile == nil && unknown.permitsNativeImport && unknown.importProfile?.id == "classic_3")
        precondition(IPodIdentity.unknown.profileID == nil && IPodIdentity.unknown.importProfile?.id == "classic_3")
        precondition(unknown.allowsManualProfile("classic_3") && !unknown.allowsManualProfile("video_1"))
        precondition(!conflict.allowsManualProfile("classic_3") && !classic.allowsManualProfile("classic_1"))
        precondition(IPodKnowledge.canonicalCode("MC293LL/A") == "C293")
        precondition(IPodKnowledge.canonicalCode("MALICIOUSC293") == nil)
        let nano = IPodKnowledge.identify(sysInfo: "ModelNumStr: MC525", extended: nil, rockboxInfo: nil)
        precondition(nano.profileID == "nano_6" && !nano.permitsNativeImport)
        let profile = classic.profile!
        let standard = NativeAudioSpec(codec: "flac", bits: 16, rate: 44100, channels: 2)
        precondition(NativeAudioPlanner.decision(spec: standard, extension: "flac", profile: profile).0 == .sameSpecALAC)
        precondition(NativeAudioPlanner.decision(spec: .init(codec: "alac", bits: 16, rate: 44100, channels: 2), extension: "m4a", profile: profile).0 == .direct)
        let hi = NativeAudioSpec(codec: "alac", bits: 24, rate: 192000, channels: 2)
        let pending = NativeAudioPlanner.decision(spec: hi, extension: "m4a", profile: profile)
        precondition(pending.0 == .deferred && pending.2?.bits == 16 && pending.2?.rate == 48000)
        precondition(NativeAudioPlanner.decision(spec: .init(codec: "alac", bits: 16, rate: 48000, channels: 2), extension: "m4a", profile: profile).0 == .direct)
        precondition(NativeAudioPlanner.decision(spec: .init(codec: "flac", bits: 16, rate: 48000, channels: 2), extension: "flac", profile: profile).0 == .sameSpecALAC)
        let family441 = NativeAudioPlanner.decision(spec: .init(codec: "alac", bits: 24, rate: 176400, channels: 2), extension: "m4a", profile: profile)
        precondition(family441.2?.rate == 44100)
        for spec in [NativeAudioSpec(codec: "alac", bits: nil, rate: 44100, channels: 2),
                     .init(codec: "alac", bits: 24, rate: 96000, channels: 6),
                     .init(codec: "flac", bits: 16, rate: 22050, channels: 2)] {
            precondition(NativeAudioPlanner.decision(spec: spec, extension: "m4a", profile: profile).0 == .unresolved)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("knowledge-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = FileSignature(size: 1, modificationDate: Date())
        func item(_ index: Int, _ disposition: NativeAudioDisposition) -> NativeAudioItem {
            .init(url: root.appendingPathComponent("\(index).m4a"), sourceRoot: root, signature: stamp, spec: hi,
                  disposition: disposition, reason: "Synthetic test", target: pending.2)
        }
        let assessment = NativeAudioAssessment(items: (0..<5).map { item($0, .direct) }
            + [item(5, .deferred), item(6, .deferred), item(7, .unresolved)])
        let device = IPodDevice(name: "Synthetic", rootURL: root, musicURL: root.appendingPathComponent("Music"),
                                writeState: .writable, isRockbox: false, hasNativeDatabase: true, identity: classic)
        let plan = NativeImportPlan(id: UUID(), device: device, engine: root.appendingPathComponent("unused"), workspace: root,
            sourceCount: 5, missing: 1, summary: .init(additions: 3, existing: 2, conversions: 0),
            databaseFiles: [:], stagedFiles: [:], assessment: assessment)
        let suite = "KnowledgeChecks.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = BridgeModel(root: root, preferences: preferences, deviceProvider: { [device] }, monitorDevices: false)
        defer { model.shutdown() }
        let review = NativeConversionReview(plan: plan, imported: 3, existing: 2)
        model.nativeReview = review
        model.skipNativeConversions(review)
        precondition(model.nativePresentation == nil && model.completed == 3 && model.skipped == 6 && model.queue == 9)
        precondition(model.phase == "本轮导入结束 · 有跳过")
        var task = NativeImportTask(plan: plan)
        precondition(task.total == 9 && task.compatible == 5 && task.pending == 2 && task.blocked == 1 && task.unmatched == 1)
        let recordRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NativeTaskChecks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: recordRoot) }
        task.imported = 3; task.existing = 2; task.stage = "首轮已完成，等待选择剩余歌曲"; task.writeVerified = true
        try task.save(root: recordRoot)
        let restored = NativeImportTask.load(root: recordRoot)
        precondition(restored?.imported == 3 && restored?.existing == 2 && restored?.pending == 2 && restored?.writeVerified == true)
        let writer = NativeTaskWriter()
        for count in 0..<10 {
            var snapshot = task; snapshot.imported = count
            writer.enqueue(snapshot, root: recordRoot) { _ in preconditionFailure("Task persistence failed") }
        }
        writer.flush()
        precondition(NativeImportTask.load(root: recordRoot)?.imported == 9)
        model.nativeTask = task
        model.recordNativePlayback(success: true)
        precondition(model.nativeTask?.playback == "待实机确认" && !model.canEjectNative)
        model.nativeTask?.ejected = true
        model.recordNativePlayback(success: false)
        model.nativePlaybackIssue = "测试：封面未显示"; model.saveNativePlaybackIssue()
        precondition(model.nativeTask?.playback == "实机反馈有问题" && model.nativeTask?.playbackIssue == "测试：封面未显示")
        var exposed = IPodDevice(name: "Synthetic unknown", rootURL: root, musicURL: root.appendingPathComponent("Music"),
            writeState: .writable, isRockbox: true, volumeIdentifier: "synthetic-session-volume",
            hasNativeDatabase: true, identity: unknown)
        let manual = BridgeModel(root: root, preferences: preferences, deviceProvider: { [exposed] }, monitorDevices: false)
        defer { manual.shutdown() }
        manual.selectedProfileID = "video_1"; manual.confirmUserModel()
        precondition(manual.device?.identity.profile == nil)
        manual.selectedProfileID = "classic_3"; manual.confirmUserModel(); manual.refreshDevice()
        precondition(manual.device?.identity.profileID == nil && manual.device?.identity.profile?.id == "classic_3")
        precondition(manual.device?.identity.evidence == unknown.evidence)
        precondition(manual.device?.identity.status.contains("用户确认") == true)
        exposed.identity = conflict; manual.refreshDevice()
        precondition(manual.device?.identity.permitsNativeImport == false)
        print("PASS: model codes, shared enclosure ID, conflicting identity, unsupported generation, strict/deferred/unknown rules, two-stage skip accounting")
    }
}
