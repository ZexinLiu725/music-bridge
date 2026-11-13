import SwiftUI

/// Shared with SettingsPage.swift since the v10 split.
enum Paint {
    static let background = SurfacePalette.window
    static let card = SurfacePalette.card
    static let input = SurfacePalette.input
    /// Ink: the primary text color. (The name predates the light theme;
    /// it is the foreground token, not the color white.)
    static let white = Color(red: 30/255, green: 30/255, blue: 32/255)
    static let secondary = Color(red: 102/255, green: 106/255, blue: 112/255)
    static let placeholder = Color(red: 150/255, green: 154/255, blue: 160/255)
    static let blue = Color(red: 40/255, green: 146/255, blue: 255/255)
    static let green = Color(red: 48/255, green: 176/255, blue: 110/255)
    static let line = Color.black.opacity(0.08)
}

struct BridgeView: View {
    @ObservedObject var model: BridgeModel
    @FocusState private var inputFocused: Bool
    @State private var deviceDetailsExpanded = false
    @State private var page: Page = .download

    /// One task per page: download, import, decode, settings. Everything
    /// in the app belongs to exactly one of the four.
    private enum Page { case download, importMusic, decode, settings }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar
            Rectangle().fill(Paint.line).frame(width: 1)
            ScrollView(.vertical) {
                Group {
                    switch page {
                    case .download: downloadPage
                    case .importMusic: importPage
                    case .decode: decodePage
                    case .settings: SettingsPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 30)
                .padding(.top, 28)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
        .background(WindowBackdrop())
        .animation(reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0), value: model.logsExpanded)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0), value: model.reviewsExpanded)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0), value: deviceDetailsExpanded)
        .onChange(of: model.logsExpanded) { _, expanded in if expanded { page = .settings } }
        .onChange(of: model.settingsExpanded) { _, expanded in if expanded { page = .settings } }
        .onReceive(NotificationCenter.default.publisher(for: .mbGoDownload)) { _ in page = .download }
        .onReceive(NotificationCenter.default.publisher(for: .mbGoImport)) { _ in page = .importMusic }
        .onReceive(NotificationCenter.default.publisher(for: .mbGoDecode)) { _ in page = .decode }
        .onReceive(NotificationCenter.default.publisher(for: .mbGoSettings)) { _ in page = .settings }
        .foregroundStyle(Paint.white)
        .font(.system(size: 13))
        .preferredColorScheme(.light)
        .environment(\.legibilityWeight, .regular)
        .ignoresSafeArea()
        .sheet(item: $model.nativePresentation) { presentation in
            switch presentation {
            case .plan(let plan):
                NativePlanReview(model: model, plan: plan, confirm: { model.confirmNativeImport(plan) }, cancel: { model.cancelNativeImport() })
                    .interactiveDismissDisabled()
            case .conversion(let review):
                NativeConversionSelection(model: model, review: review, convert: { model.convertNativeSelections(review, selectedIDs: $0) },
                                          skip: { model.skipNativeConversions(review) })
                    .interactiveDismissDisabled()
            case .initialize(let request):
                NativeInitializationView(model: model, request: request).interactiveDismissDisabled()
            }
        }
        .sheet(item: $model.rockboxPreview) { preview in
            RockboxPlanReview(preview: preview, confirm: { model.confirmRockboxImport(preview) },
                              cancel: { model.cancelRockboxPreview() })
                .interactiveDismissDisabled()
        }
    }

    /// Left navigation in the shape of the mature desktop apps: identity
    /// at the top, the three destinations in the middle, and the NetEase
    /// account anchored at the bottom where a user row belongs.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                // The mark is the device itself: the user's iPod Classic,
                // drawn by the same glyph the import page uses.
                IPodGlyph()
                    .scaleEffect(0.62)
                    .frame(width: 24, height: 38)
                Text("Music Bridge").font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
            navRow(.download, icon: "arrow.down.circle.fill", label: "下载")
            navRow(.importMusic, icon: "tray.and.arrow.down.fill", label: "导入")
            navRow(.decode, icon: "lock.open.fill", label: "解码")
            navRow(.settings, icon: "gearshape.fill", label: "设置")
            Spacer(minLength: 12)
            sidebarAccount
        }
        .padding(.horizontal, 14)
        .padding(.top, 36)
        .padding(.bottom, 14)
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Color(red: 250/255, green: 250/255, blue: 252/255))
    }

    private func navRow(_ target: Page, icon: String, label: String) -> some View {
        Button { page = target } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 13, weight: page == target ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(page == target ? Paint.white : Paint.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(page == target ? Color.black.opacity(0.055) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pageHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Paint.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The account lives at the bottom of the sidebar. Signed out, the row
    /// is the sign-in entry (jump to settings, the QR code appears there);
    /// signed in, it shows who and which tier, and leads to the settings
    /// page, where sign-out lives.
    private var sidebarAccount: some View {
        Button {
            page = .settings
            if model.neteaseNickname == nil { model.startNeteaseLogin() }
        } label: {
            HStack(spacing: 9) {
                Circle().fill(model.neteaseNickname != nil ? Paint.green : Paint.placeholder).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.neteaseNickname ?? "网易云未登录")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Paint.white).lineLimit(1)
                    Text(model.neteaseNickname == nil ? "点此扫码登录" : (model.neteaseIsVIP ? "黑胶 VIP" : "普通账号"))
                        .font(.system(size: 11)).foregroundStyle(Paint.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Paint.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var downloadPage: some View {
        VStack(spacing: 20) {
            pageHeader("下载", "粘贴歌单链接，剩下的交给它。")
            journeySteps
            if !model.wrapperReady && !model.appleServiceSeenReady {
                appleLoginBanner
            }
            sourceCard
            progressCard
            if !model.reviewableSkips.isEmpty {
                reviewsCard
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
    }

    // The whole journey on one line, so a first-time user sees the path
    // before touching anything: paste, download, import. The lit step
    // follows the model, so the strip doubles as a progress guide; when
    // a download has finished, the import step is tappable and jumps
    // straight to the import page.
    private var journeySteps: some View {
        let stage = journeyStage
        return HStack(spacing: 8) {
            journeyStep(icon: "link", label: "粘贴链接", position: 0, stage: stage)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Paint.placeholder)
            journeyStep(icon: "arrow.down.circle.fill", label: "下载到电脑", position: 1, stage: stage)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Paint.placeholder)
            journeyStep(icon: "tray.and.arrow.down.fill", label: "导入 iPod", position: 2, stage: stage)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var journeyStage: Int {
        if model.importing { return 2 }
        if model.busy { return 1 }
        if model.completed > 0 || model.skipped > 0 { return 2 }
        return 0
    }

    @ViewBuilder
    private func journeyStep(icon: String, label: String, position: Int, stage: Int) -> some View {
        let active = position == stage
        let done = position < stage
        let content = HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(done ? Paint.green : active ? Paint.blue : Paint.placeholder)
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Paint.white : Paint.secondary)
        }
        if position == 2 && active && !model.busy {
            Button { page = .importMusic } label: { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    /// First-run guidance for the one step that happens outside the
    /// app: until an Apple account has been signed in once, downloads
    /// cannot start, so the download page says so up front — with the
    /// way in — instead of letting the first download fail.
    private var appleLoginBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 20)).foregroundStyle(Paint.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text("先登录一次 Apple 账号").font(.system(size: 13, weight: .semibold))
                Text("下载 Apple Music 前要完成一次登录：在打开的终端里输账号和密码，App 不保存。登过一次之后就不用再管。")
                    .font(.system(size: 12)).foregroundStyle(Paint.secondary)
            }
            Spacer(minLength: 0)
            Button("登录 Apple 账号") { model.openAppleLogin() }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }

    private var importPage: some View {
        VStack(spacing: 20) {
            pageHeader("导入", "把下载好的歌送进 iPod。")
            deviceCard
            if let task = model.nativeTask {
                NativeTaskSummary(model: model, task: task).floatingSurface()
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
    }

    private var decodePage: some View {
        VStack(spacing: 20) {
            pageHeader("解码", "把网易云下载的 .ncm 解出成普通音频。")
            ncmCard
            if model.busy {
                decodeStatusCard
            }
            ncmInfoCard
        }
        .frame(maxWidth: 780, alignment: .leading)
    }

    /// While a decode runs, the shared task fields carry its progress;
    /// show them in the same icon-and-two-lines strip the cards use.
    private var decodeStatusCard: some View {
        HStack(spacing: 14) {
            BridgeIcon(kind: .music)
                .frame(width: 18, height: 18).foregroundStyle(Paint.secondary)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.taskTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.taskDetail).font(.system(size: 11)).foregroundStyle(Paint.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }

    private var ncmInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("解码之后").font(.system(size: 15, weight: .semibold))
            Text("音频落在项目目录的「NCM 导入」文件夹，文件名是「歌手 - 歌名」。")
                .font(.system(size: 12)).foregroundStyle(Paint.secondary)
            Text("Rockbox 模式且 iPod 已连接时，解码完会自动跳到导入页，确认后才写入设备。")
                .font(.system(size: 12)).foregroundStyle(Paint.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }


    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("歌单来源").font(.system(size: 15, weight: .semibold))
                Spacer()
                BridgeIcon(kind: .link).frame(width: 12, height: 12).foregroundStyle(Paint.secondary)
                Text(sourceStatus).font(.system(size: 12, weight: .regular)).foregroundStyle(Paint.secondary)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: sourceStatus)
            }
            HStack(spacing: 10) {
                HStack(spacing: 11) {
                    BridgeIcon(kind: .link).frame(width: 14, height: 14).foregroundStyle(Paint.placeholder)
                    ZStack(alignment: .leading) {
                        if model.source.isEmpty {
                            Text("粘贴公开歌单链接...").foregroundStyle(Paint.placeholder).allowsHitTesting(false)
                        }
                        TextField("", text: $model.source)
                        .textFieldStyle(.plain)
                        .focused($inputFocused)
                        .onSubmit { model.startOrStop() }
                        .onExitCommand { inputFocused = false }
                        .accessibilityLabel("公开歌单链接")
                        .disabled(model.busy || model.importing)
                    }.font(.system(size: 16, weight: .regular))
                    Button { model.source = ""; inputFocused = true } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Paint.placeholder.opacity(model.source.isEmpty ? 0.6 : 1))
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy || model.importing)
                    .accessibilityLabel("清除链接")
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Paint.input, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(inputFocused ? Paint.blue : Color.black.opacity(0.14), lineWidth: 1))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: inputFocused)
                Button { model.startOrStop() } label: {
                    HStack(spacing: 10) {
                        BridgeIcon(kind: model.busy ? .stop : .download).frame(width: 16, height: 16)
                        Text(model.busy ? "停止" : "开始")
                    }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 108, height: 46)
                }
                .buttonStyle(BlueButtonStyle())
                .disabled(model.importing || model.loadingLocalState)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.top, 16)
            // Recognition scope reads as marks, not a sentence: one quiet
            // pill per platform.
            HStack(spacing: 6) {
                platformChip("网易云")
                platformChip("QQ 音乐")
                platformChip("酷狗")
                platformChip("Apple Music")
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            if model.loadingLocalState {
                HStack {
                    Text("本地记录读取中").foregroundStyle(Paint.secondary)
                    Button("选择项目文件夹") { model.chooseProjectAccess() }.buttonStyle(.link)
                }.font(.system(size: 11)).padding(.top, 6)
            }
        }
        .padding(23)
        .frame(maxWidth: .infinity, minHeight: model.loadingLocalState ? 205 : 181, alignment: .topLeading)
        .floatingSurface(editing: inputFocused)
    }

    private var sourceStatus: String {
        if model.source.isEmpty { return "等待链接" }
        switch PlaylistSource.identify(model.source) {
        case .apple: return "Apple Music"
        case .netease: return "网易云歌单"
        case .qq: return "QQ 音乐歌单"
        case .kugou: return "酷狗歌单"
        case nil: return "请检查链接"
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 8) {
                    Circle().fill(model.failed ? Color.red : (model.busy || model.importing) ? Paint.blue : Paint.placeholder).frame(width: 8, height: 8)
                    Text(model.phase).font(.system(size: 14, weight: .semibold))
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.phase)
                }
                Spacer()
                Text(model.importing && model.queue == nil ? "统计中" : "\(Int(model.percent))%")
                    .font(.system(size: model.importing && model.queue == nil ? 18 : 28, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: model.percent))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: Int(model.percent))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.08))
                    Capsule().fill(Paint.blue).frame(width: proxy.size.width * min(1, max(0, model.percent / 100)))
                        .animation(reduceMotion ? nil : .linear(duration: 0.16), value: model.percent)
                }
            }
            .frame(height: 7).padding(.top, 13)
            HStack(spacing: 0) {
                metric(model.queue.map(String.init) ?? "—", "队列")
                Rectangle().fill(Paint.line).frame(width: 1)
                metric(String(model.completed), "已完成")
                Rectangle().fill(Paint.line).frame(width: 1)
                metric(String(model.skipped), "跳过")
            }
            .frame(height: 67)
            .overlay(alignment: .top) { Rectangle().fill(Paint.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Paint.line).frame(height: 1) }
            .padding(.top, 16)
            HStack(spacing: 12) {
                BridgeIcon(kind: .music)
                    .frame(width: 18, height: 18).foregroundStyle(Paint.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.taskTitle).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(model.taskDetail).font(.system(size: 11)).foregroundStyle(Paint.secondary).lineSpacing(2).lineLimit(2)
                }
                .offset(x: -1, y: -1.5)
                Spacer(minLength: 0)
            }
            .padding(.top, 21)
        }
        .padding(.horizontal, 23)
        .padding(.top, 19)
        .padding(.bottom, 23)
        .frame(maxWidth: .infinity, minHeight: 234, maxHeight: 234, alignment: .topLeading)
        .floatingSurface()
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: value)
            Text(label).font(.system(size: 11)).foregroundStyle(Paint.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func platformChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Paint.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.045), in: Capsule())
    }

    /// Stage 5c entry: .ncm files from the official NetEase client are
    /// decoded locally, then handed to the same import flow.
    private var ncmCard: some View {
        HStack(spacing: 14) {
            BridgeIcon(kind: .music)
                .frame(width: 18, height: 18).foregroundStyle(Paint.secondary)
                .frame(width: 34, height: 34)
                .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text("网易云 .ncm 文件").font(.system(size: 15, weight: .semibold))
                Text("官方客户端下载的加密文件，本地解码后导入。")
                    .font(.system(size: 12)).foregroundStyle(Paint.secondary)
            }
            Spacer(minLength: 0)
            Button("选择文件或文件夹…") { model.importNCM() }
                .disabled(model.busy || model.importing)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                IPodGlyph().frame(width: 42, height: 64).offset(y: -2)
                Spacer()
                HStack(spacing: 7) {
                    Circle().fill(deviceConnected ? Paint.green : Paint.placeholder).frame(width: 6, height: 6)
                    Text(model.deviceStatus).font(.system(size: 11, weight: .semibold))
                        .contentTransition(.opacity)
                }
                .foregroundStyle(deviceConnected ? Paint.green : Paint.secondary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background((deviceConnected ? Paint.green : Paint.secondary).opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                .offset(y: -5.5)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.deviceStatus)
            }
            .padding(.top, 2).padding(.leading, 4)
            if !model.availableDevices.isEmpty {
                Picker("选择设备", selection: Binding(get: {
                    model.availableDevices.contains(where: { $0.selectionKey == model.selectedDeviceKey }) ? model.selectedDeviceKey : ""
                }, set: { model.selectDevice($0) })) {
                    Text("请选择设备").tag("")
                    ForEach(model.availableDevices, id: \.selectionKey) { candidate in
                        Text(candidate.name + " · " + candidate.rootURL.lastPathComponent).tag(candidate.selectionKey)
                    }
                }.disabled(model.busy || model.importing).padding(.top, 12)
            }
            Text(model.device?.name ?? (model.availableDevices.isEmpty ? "iPod 未连接" : "请选择目标设备"))
                .font(.system(size: 20, weight: .bold)).tracking(-0.5)
                .padding(.top, 20).lineLimit(1)
            Text(model.device?.systemDescription ?? "连接 iPod 后可导入音乐")
                .font(.system(size: 13)).foregroundStyle(Paint.secondary).padding(.top, 3)
            Rectangle().fill(Paint.line).frame(height: 1).padding(.top, 19)
            VStack(spacing: 9) {
                deviceRow("导入目标", model.device == nil ? "未选择设备" : model.needsNativeInitialization ? "待建立原生音乐库" : model.resolvedImportMode == .native ? "原生音乐库" : model.resolvedImportMode == .rockbox ? "Music/" : "当前不可用")
                if let available = model.device?.availableBytes {
                    deviceRow("可用空间", ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
                    if let total = model.device?.totalBytes, total > 0 {
                        capacityBar(usedFraction: Double(total - available) / Double(total))
                    }
                }
            }
            .padding(.vertical, 15)
            Rectangle().fill(Paint.line).frame(height: 1)
            Button { deviceDetailsExpanded.toggle() } label: {
                HStack {
                    Text("设备详情").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Paint.secondary)
                        .rotationEffect(.degrees(deviceDetailsExpanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: deviceDetailsExpanded)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            if deviceDetailsExpanded {
                VStack(spacing: 9) {
                    deviceRow("文件系统", model.device?.formatDescription ?? "未读取")
                    deviceRow("写入权限", model.device.map { $0.writeState.rawValue + "（系统报告）" } ?? "未连接")
                    deviceRow("挂载点", model.device?.rootURL.path ?? "—")
                    deviceRow("原生导入配置", model.device?.identity.importProfile?.name ?? "未确定")
                    if let device = model.device {
                        deviceRow("硬件确认", device.identity.usbIPodConfirmed ? "已关联 iPod USB 设备" : "仅依据曲库或型号文件")
                    }
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -5)))
                if let device = model.device {
                    HStack(alignment: .firstTextBaseline) {
                        Text(device.identity.title).font(.system(size: 11)).foregroundStyle(Paint.secondary)
                        Spacer(minLength: 4)
                        Button("兼容详情") { model.compatibilityDetails = true }
                            .buttonStyle(.link).font(.system(size: 11))
                            .popover(isPresented: $model.compatibilityDetails) { IPodCompatibilityDetails(model: model, device: device) }
                    }.padding(.top, 10)
                }
            }
            Picker("导入方式", selection: $model.importMode) {
                ForEach(IPodImportMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .disabled(model.busy || model.importing)
            .accessibilityLabel("iPod 导入方式")
            .padding(.top, 16)
            Button { model.importMusic() } label: {
                HStack(spacing: 10) {
                    BridgeIcon(kind: .importMusic).frame(width: 16, height: 16)
                    Text(model.importActionTitle)
                }
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 46)
            }
            .buttonStyle(BlueButtonStyle())
            .disabled(!model.canImport || (model.resolvedImportMode == nil && !model.needsNativeInitialization)
                      || (model.needsNativeInitialization && model.device?.identity.nativeFamilyUnsupported == true)
                      || (model.resolvedImportMode == .native && model.device?.identity.permitsNativeImport != true))
            .padding(.top, 12)
            Text(model.importHint)
                .font(.system(size: 11)).foregroundStyle(Paint.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 11)
            Button("重新检查设备") { model.recheckDeviceFiles() }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Paint.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.black.opacity(0.045), in: Capsule())
                .disabled(model.busy || model.importing || model.checkingDevice).padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(23)
        .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
        .floatingSurface()
    }

    private var deviceConnected: Bool { model.device != nil && !model.deviceIOFailure }

    /// Storage as a bar, not a sentence: fullness reads at a glance,
    /// and the bar turns red when the device is nearly full.
    private func capacityBar(usedFraction: Double) -> some View {
        let fraction = min(1, max(0, usedFraction))
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.08))
                Capsule().fill(fraction > 0.92 ? Color.red : Paint.blue)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
        .accessibilityLabel("已用空间 \(Int((fraction * 100).rounded()))%")
    }

    private func deviceRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Paint.secondary)
            Spacer()
            Text(value).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
        }.font(.system(size: 12))
    }


    /// Skips with a reviewable candidate: part of the download flow, so
    /// it lives on the download page, shown only while it is non-empty.
    private var reviewsCard: some View {
        VStack(spacing: 0) {
            DisclosureHeaderRow(title: "跳过复核", detail: "\(model.reviewableSkips.count) 首有候选", expanded: model.reviewsExpanded) { model.reviewsExpanded.toggle() }
            if model.reviewsExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.reviewableSkips) { skip in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(skip.artist.isEmpty ? skip.title : "\(skip.title) · \(skip.artist)")
                                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Paint.white)
                                Text("候选：《\(skip.candidateTitle)》· \(skip.candidateArtist)" + (skip.candidateAlbum.map { " · \($0)" } ?? ""))
                                    .foregroundStyle(Paint.secondary)
                                Text("未自动下载：\(skip.reason)（相似度 \(Int((skip.score * 100).rounded()))%）")
                                    .foregroundStyle(Paint.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("就下这首") { model.downloadReview(skip) }
                                .disabled(model.busy || model.importing)
                        }
                    }
                    Text("没通过自动匹配的不会自动下载，确认后可单独下回。")
                        .foregroundStyle(Paint.secondary)
                }
                .font(.system(size: 12)).padding(.horizontal, 20).padding(.bottom, 20)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -5)))
            }
        }
        .floatingSurface()
    }

}

private struct BridgeIcon: View {
    enum Kind { case link, download, importMusic, music, stop }
    let kind: Kind
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 24
            Path { path in
                switch kind {
                case .download:
                    path.move(to: CGPoint(x: 12, y: 3)); path.addLine(to: CGPoint(x: 12, y: 15))
                    path.move(to: CGPoint(x: 7, y: 10)); path.addLine(to: CGPoint(x: 12, y: 15)); path.addLine(to: CGPoint(x: 17, y: 10))
                    path.move(to: CGPoint(x: 5, y: 21)); path.addLine(to: CGPoint(x: 19, y: 21))
                case .importMusic:
                    path.move(to: CGPoint(x: 5, y: 3)); path.addLine(to: CGPoint(x: 19, y: 3))
                    path.move(to: CGPoint(x: 12, y: 21)); path.addLine(to: CGPoint(x: 12, y: 9))
                    path.move(to: CGPoint(x: 7, y: 14)); path.addLine(to: CGPoint(x: 12, y: 9)); path.addLine(to: CGPoint(x: 17, y: 14))
                case .link:
                    path.move(to: CGPoint(x: 10, y: 13))
                    path.addCurve(to: CGPoint(x: 17, y: 13), control1: CGPoint(x: 11.8, y: 15), control2: CGPoint(x: 15, y: 15))
                    path.addLine(to: CGPoint(x: 20, y: 10))
                    path.addCurve(to: CGPoint(x: 13, y: 3), control1: CGPoint(x: 24.5, y: 5.5), control2: CGPoint(x: 17.5, y: -1.5))
                    path.addLine(to: CGPoint(x: 11, y: 5))
                    path.move(to: CGPoint(x: 14, y: 11))
                    path.addCurve(to: CGPoint(x: 7, y: 11), control1: CGPoint(x: 12.2, y: 9), control2: CGPoint(x: 9, y: 9))
                    path.addLine(to: CGPoint(x: 4, y: 14))
                    path.addCurve(to: CGPoint(x: 11, y: 21), control1: CGPoint(x: -0.5, y: 18.5), control2: CGPoint(x: 6.5, y: 25.5))
                    path.addLine(to: CGPoint(x: 13, y: 19))
                case .music:
                    path.move(to: CGPoint(x: 9, y: 18)); path.addLine(to: CGPoint(x: 9, y: 5)); path.addLine(to: CGPoint(x: 21, y: 3)); path.addLine(to: CGPoint(x: 21, y: 16))
                    path.move(to: CGPoint(x: 9, y: 9)); path.addLine(to: CGPoint(x: 21, y: 7))
                    path.addEllipse(in: CGRect(x: 3, y: 15, width: 6, height: 6))
                    path.addEllipse(in: CGRect(x: 15, y: 13, width: 6, height: 6))
                case .stop:
                    path.addRoundedRect(in: CGRect(x: 5, y: 5, width: 14, height: 14), cornerSize: CGSize(width: 1, height: 1))
                }
            }
            .applying(CGAffineTransform(scaleX: scale, y: scale))
            .stroke(style: StrokeStyle(lineWidth: 1.8 * scale, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct BlueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        ActionButtonSurface(label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
    }
}

private final class ActionButtonState: ObservableObject {
    @Published var hovered = false
}

private struct ActionButtonSurface<Label: View>: View {
    let label: Label
    let pressed: Bool
    let enabled: Bool
    @StateObject private var state = ActionButtonState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        // Enabled, the label is true white on the blue fill (Paint.white
        // is the ink token and would be wrong there). Disabled follows
        // the platform habit instead: gray fill, secondary label, no sheen.
        label.foregroundStyle(enabled ? Color.white : Paint.secondary)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(enabled ? Paint.blue.opacity(pressed ? 0.82 : 1) : Color.black.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [Color.white.opacity(!enabled ? 0 : state.hovered ? 0.12 : 0.035), .clear], startPoint: .top, endPoint: .bottom))
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .scaleEffect(enabled && pressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.hovered)
            .onHover { state.hovered = $0 && enabled && activeState != .inactive }
            .onChange(of: enabled) { _, value in if !value { state.hovered = false } }
            .onChange(of: activeState) { _, value in if value == .inactive { state.hovered = false } }
            .onDisappear { state.hovered = false }
    }
}

private struct IPodGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.30), lineWidth: 1.4))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Color(red: 172/255, green: 182/255, blue: 192/255)).frame(height: 20)
                ZStack {
                    Circle().fill(Color.black.opacity(0.05)).frame(width: 23, height: 23)
                    Circle().fill(Color.black.opacity(0.14)).frame(width: 7, height: 7)
                    VStack { Capsule().fill(Color.black.opacity(0.30)).frame(width: 4, height: 1); Spacer(); Capsule().fill(Color.black.opacity(0.30)).frame(width: 1, height: 3) }.frame(height: 19)
                    HStack { Capsule().fill(Color.black.opacity(0.30)).frame(width: 3, height: 1); Spacer(); Capsule().fill(Color.black.opacity(0.30)).frame(width: 3, height: 1) }.frame(width: 19)
                }
            }.padding(5)
        }
        .frame(width: 36, height: 59)
        .accessibilityLabel("iPod")
    }
}
