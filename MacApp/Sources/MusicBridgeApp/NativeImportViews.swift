import SwiftUI

struct RockboxPlanReview: View {
    let preview: RockboxImportPreview
    let confirm: () -> Void
    let cancel: () -> Void
    private var spaceInsufficient: Bool {
        guard let available = preview.device.availableBytes, available >= 0 else { return false }
        return preview.bytesNeeded > UInt64(available)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认 Rockbox 导入").font(.title2.bold())
            Text("目标设备：\(preview.device.name)" + (preview.playlistName.map { " · 歌单：\($0)" } ?? ""))
            Text("可处理 \(preview.ready.count) 首 · 已有且内容一致 \(preview.items.filter { $0.status.hasPrefix("已有") }.count) 首 · 冲突 \(preview.items.filter { $0.status.hasPrefix("同名") }.count) 首 · 其他未确认 \(preview.items.filter { !$0.canCopy && !$0.status.hasPrefix("同名") }.count) 首 · 未匹配 \(preview.missing) 首")
            Text("歌曲预计占用 \(ByteCountFormatter.string(fromByteCount: Int64(clamping: preview.bytesNeeded), countStyle: .file))；封面与文件系统开销另计。" +
                 (preview.device.availableBytes.map { " 设备可用 \(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file))。" } ?? " 设备可用空间未知。"))
                .foregroundStyle(spaceInsufficient ? .red : .secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(preview.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.url.lastPathComponent).fontWeight(.medium)
                            Text(item.spec.map { spec in
                                "\(spec.codec.uppercased()) · \(spec.bits.map { "\($0) bit" } ?? "位深未知") · \(spec.rate) Hz · \(spec.channels) 声道"
                            } ?? "音频规格未知")
                            Text(item.status).foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 300)
            Text("原样复制，不修改设备配置。识别结果不代表真机播放已验证；歌单保存在设备的 Music 文件夹，导入后请在 Rockbox 更新数据库。")
                .font(.callout).foregroundStyle(.secondary)
            if preview.playlistID != nil {
                Text("全部歌曲复制或核对一致后生成 M3U8 歌单；如有未匹配或冲突，本次不生成完整歌单。内容变化时保留旧歌单并另存新版本。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("处理 \(preview.ready.count) 首", action: confirm).keyboardShortcut(.defaultAction)
                    .disabled(preview.ready.isEmpty || spaceInsufficient)
            }
        }.padding(26).frame(width: 620)
    }
}

struct NativeConversionReview: Sendable, Identifiable {
    let id = UUID()
    let plan: NativeImportPlan
    let imported: Int
    let existing: Int
    var pending: [NativeAudioItem] { plan.assessment?.pending ?? [] }
    var blocked: [NativeAudioItem] { plan.assessment?.blocked ?? [] }
}

enum NativeImportPresentation: Identifiable {
    case plan(NativeImportPlan), conversion(NativeConversionReview), initialize(NativeInitializationRequest)
    var id: String {
        switch self { case .plan(let p): return "plan-" + p.id.uuidString
        case .conversion(let r): return "conversion-" + r.id.uuidString
        case .initialize(let r): return "initialize-" + r.id.uuidString }
    }
}

struct NativePlanReview: View {
    @ObservedObject var model: BridgeModel
    let plan: NativeImportPlan
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认首轮原生导入").font(.title2.bold())
            Text("导入目标：" + (plan.device.identity.importProfile?.name ?? "待确认")).font(.headline)
            Text("设备记录：" + plan.device.identity.title + " · " + plan.device.identity.status).font(.callout).foregroundStyle(.secondary)
            Text("预计新增 \(plan.summary.additions) 首 · 已有 \(plan.summary.existing) 首")
            if let assessment = plan.assessment {
                Text("同规格 ALAC 转换 \(assessment.sameSpecCount) 首 · 原有有损音源原样导入 \(assessment.lossyCount) 首")
                Text("留待选择转换 \(assessment.pending.count) 首 · 无法确认 \(assessment.blocked.count) 首 · 未匹配 \(plan.missing) 首")
                DisclosureGroup("查看首轮兼容歌曲与规格") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(assessment.ready) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.url.lastPathComponent).fontWeight(.medium)
                                    Text(item.spec?.description ?? "规格未知")
                                    Text(item.reason).foregroundStyle(.secondary)
                                    Button("显示原文件") { model.revealOriginal(item.url) }.buttonStyle(.link)
                                }.font(.callout)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 200)
                }
            }
            Text(IPodKnowledge.policyNote(for: plan.device.identity)).font(.callout).foregroundStyle(.secondary)
            if let playlist = plan.playlist { Text("自动维护播放列表「\(playlist.name)」，按源歌单顺序补齐已导入歌曲。") }
            Text("写入前备份数据库。首轮保持音频规格；待转换歌曲在首轮结束后单独选择。实机显示与播放将在安全弹出后确认。")
            HStack {
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("备份并导入兼容歌曲", action: confirm).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 560)
    }
}

struct NativeConversionSelection: View {
    @ObservedObject var model: BridgeModel
    let review: NativeConversionReview
    let convert: (Set<String>) -> Void
    let skip: () -> Void
    private var selected: Set<String> { model.nativeSelectedIDs }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("兼容歌曲已处理，选择剩余歌曲").font(.title2.bold())
            Text("已新增 \(review.imported) 首 · 已有 \(review.existing) 首 · 待转换 \(review.pending.count) 首 · 无法确认 \(review.blocked.count) 首")
            Text("按所选机型的导入目标生成副本。降低位深或采样率会损失原始信息；原文件保留。未选择的歌曲本次跳过。")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("全选待转换歌曲") { model.nativeSelectedIDs = Set(review.pending.map(\.id)) }
                Button("取消全选") { model.nativeSelectedIDs = [] }
                Spacer()
                Text("未匹配 \(review.plan.missing) 首").foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(review.pending) { item in
                        Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { on in
                            if on { model.nativeSelectedIDs.insert(item.id) } else { model.nativeSelectedIDs.remove(item.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.url.lastPathComponent).fontWeight(.semibold)
                                Text((item.spec?.description ?? "规格未知") + " → " + (item.target?.description ?? "暂无目标"))
                                Text(item.reason).foregroundStyle(.secondary)
                                Button("在访达中显示原文件") { model.revealOriginal(item.url) }.buttonStyle(.link)
                            }.font(.callout)
                        }.toggleStyle(.checkbox)
                    }
                    ForEach(review.blocked) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.url.lastPathComponent, systemImage: "exclamationmark.triangle")
                            Text(item.reason).foregroundStyle(.secondary)
                        }.font(.callout)
                    }
                    if review.plan.missing > 0 { Text("另有 \(review.plan.missing) 首未找到唯一的本地匹配。") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120, maxHeight: 300)
            HStack {
                Button("本次跳过", action: skip).keyboardShortcut(.cancelAction)
                Spacer()
                Button("转换所选 \(selected.count) 首并继续导入") { convert(selected) }
                    .disabled(selected.isEmpty)
            }
        }.padding(26).frame(width: 650)
    }
}

struct NativeInitializationView: View {
    @ObservedObject var model: BridgeModel
    let request: NativeInitializationRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("建立原生音乐库").font(.title2.bold())
            Text("设备记录：" + request.device.identity.title)
            Text(request.device.identity.status).foregroundStyle(.secondary)
            Text("将先备份 iPod_Control 中的设备信息，再创建空曲库及音乐、封面目录。Rockbox 和现有歌曲保留；已有原生数据库不会被覆盖。")
            Picker("初始化机型", selection: $model.selectedProfileID) {
                ForEach(IPodKnowledge.profiles.filter { profile in
                    profile.nativeWriterSupported && (request.device.identity.profileID == profile.id || request.device.identity.allowsManualProfile(profile.id))
                }) { Text($0.name).tag($0.id) }
            }
            Text("默认导入目标不等于实际识别结果。初始化必须按已核对的机型明确选择；软件会读取当前设备的真实硬件标识。")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("已核对机型，按所选配置建立原生曲库", isOn: $model.nativeInitializationAcknowledged)
                .toggleStyle(.checkbox)
            HStack {
                Button("取消") { model.nativePresentation = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("备份并初始化") { model.initializeNativeLibrary(request) }
                    .disabled(!model.nativeInitializationAcknowledged || !(request.device.identity.profileID == model.selectedProfileID || request.device.identity.allowsManualProfile(model.selectedProfileID)))
            }
        }.padding(26).frame(width: 560)
    }
}

struct NativeTaskSummary: View {
    @ObservedObject var model: BridgeModel
    let task: NativeImportTask
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.playlistName ?? "原生导入任务").font(.headline)
            Text("共 \(task.total) 首 · 首轮兼容 \(task.compatible) 首 · 新增 \(task.imported) 首 · 已有 \(task.existing) 首")
            Text("待转换 \(task.pending) 首 · 无法确认 \(task.blocked) 首 · 未匹配 \(task.unmatched) 首 · 转换失败 \(task.conversionFailures) 首")
                .font(.callout).foregroundStyle(.secondary)
            Text(task.stage).font(.callout)
            if let count = task.playlistCount { Text("原生播放列表已回读核对：\(count) 首").font(.callout) }
            DisclosureGroup("查看每首歌曲的规格与处理结果") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(task.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.original.lastPathComponent + " · " + entry.status).fontWeight(.medium)
                                Text(entry.sourceSpec + " → " + entry.targetSpec)
                                Text(entry.detail).foregroundStyle(.secondary)
                                HStack {
                                    Button("显示原文件") { model.revealOriginal(entry.original) }
                                    if let converted = entry.converted { Button("显示兼容副本") { model.revealOriginal(converted) } }
                                }.buttonStyle(.link)
                            }.font(.callout)
                        }
                        ForEach(task.unmatchedSongs.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(task.unmatchedSongs[index].title + " · " + task.unmatchedSongs[index].artist)
                                Text("未找到唯一的本地匹配；未用其他版本替换。").foregroundStyle(.secondary)
                            }.font(.callout)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 260)
            }
            if let backup = task.backups.last { Button("打开曲库备份") { model.revealOriginal(backup) }.buttonStyle(.link) }
            if task.writeVerified {
                Divider()
                Text("\(task.ejected ? "已安全弹出" : "设备文件与数据库已核对") · \(task.playback)").font(.callout)
                if task.playback == "待实机确认" {
                    Text("安全弹出后，在 iPod 原生菜单检查歌单、封面和播放。电脑端核对不代表已实机播放。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("安全弹出 iPod") { model.ejectNativeDevice() }.disabled(!model.canEjectNative)
                        if model.canConfirmExternalEjection {
                            Button("已在系统中安全弹出") { model.confirmExternalEjection() }
                        }
                        Button("播放正常") { model.recordNativePlayback(success: true) }.disabled(!task.ejected)
                        Button("遇到问题") { model.recordNativePlayback(success: false) }.disabled(!task.ejected)
                    }
                }
                if task.playback == "实机反馈有问题" {
                    TextField("记录具体问题，例如：歌单不显示、某首无法播放", text: $model.nativePlaybackIssue)
                    Button("保存问题说明") { model.saveNativePlaybackIssue() }
                    Button("问题已解决，确认播放正常") { model.recordNativePlayback(success: true) }
                }
                if !task.playbackIssue.isEmpty { Text("问题记录：" + task.playbackIssue).font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(23).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IPodCompatibilityDetails: View {
    @ObservedObject var model: BridgeModel
    let device: IPodDevice
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(device.identity.title).font(.headline)
            Text(device.identity.status)
            Text("导入目标：" + (device.identity.importProfile?.name ?? "不可用"))
            if let firmware = device.identity.firmware { Text("固件标识：" + firmware) }
            ForEach(device.identity.evidence, id: \.self) { Text($0).font(.callout) }
            Text(device.identity.usbEvidence ?? "USB 信息暂不可用；未关联其他设备的信息。")
                .font(.callout)
            Text("不凭容量识别代数。外壳 A1238 不能区分 Classic 各版本；USB 只核对已知家族，不判断具体代数。")
                .font(.callout).foregroundStyle(.secondary)
            if device.identity.permitsNativeImport { Text(IPodKnowledge.policyNote(for: device.identity)).font(.callout) }
            else { Text("该身份尚不能用于原生自动导入。Rockbox 原有路径不受影响。") }
            if device.identity.profileID == nil, !device.identity.conflict, device.volumeIdentifier != nil {
                Picker("补充机型", selection: $model.selectedProfileID) {
                    Text("请选择已核对的型号").tag("")
                    ForEach(IPodKnowledge.profiles.filter { device.identity.allowsManualProfile($0.id) }) { Text($0.name).tag($0.id) }
                }
                Text("手动确认单独标记，仅用于本次会话；选错型号可能无法播放，不会覆盖原始检测记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("按所选型号确认") { model.confirmUserModel() }
                    .disabled(!device.identity.allowsManualProfile(model.selectedProfileID) || model.busy || model.importing)
            }
            Link("Apple 机型识别资料", destination: URL(string: IPodKnowledge.identificationSource)!)
            Link("型号代码依据（libgpod）", destination: URL(string: IPodKnowledge.codeSource)!)
            Link("Classic 3G 官方格式资料（不含 ALAC 位深/采样率上限）", destination: URL(string: "https://support.apple.com/kb/SP572?locale=en_US")!)
            Text("知识库 " + IPodKnowledge.version + " · 实机播放 / DAC 输出未验证")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 420)
    }
}
