import AppKit
import SwiftUI

/// The settings page as its own view, split out of BridgeView in v10:
/// account, download preferences, advanced settings, the run log and
/// the version row. Paint and floatingSurface are module-level and
/// shared with BridgeView.
struct SettingsPage: View {
    @ObservedObject var model: BridgeModel
    @State private var advancedExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        settingsPage
            .animation(reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0), value: advancedExpanded)
            .animation(reduceMotion ? nil : .smooth(duration: 0.24, extraBounce: 0), value: model.logsExpanded)
    }

    private func pageHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .semibold)).tracking(-0.4)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(Paint.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsPage: some View {
        VStack(spacing: 20) {
            pageHeader("设置", "账号、下载偏好与运行日志。")
            if model.neteaseQRImage != nil {
                qrCard
            }
            appleAccountCard
            accountCard
            disclosures
            logCard
            versionRow
        }
        .frame(maxWidth: 780, alignment: .leading)
    }

    /// Version row pinned to the bottom of the settings page: the
    /// standard place a Mac user looks for it, next to About.
    private var versionRow: some View {
        HStack {
            Text("版本").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(appVersion).foregroundStyle(Paint.secondary)
        }
        .padding(.horizontal, 20).frame(height: 50)
        .floatingSurface()
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short)（\(build)）"
    }

    /// Shown on the settings page while a NetEase QR login is in progress.
    private var qrCard: some View {
        HStack(spacing: 16) {
            if let qr = model.neteaseQRImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 148, height: 148)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("用网易云 App 扫码登录").font(.system(size: 14, weight: .semibold))
                Text(model.neteaseLoginPhaseText).foregroundStyle(Paint.secondary)
                Button("取消") { model.cancelNeteaseLogin() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }

    /// Apple sign-in happens in a terminal (the wrapper's own login
    /// script), so this card is the guided path into it: the current
    /// state, a button that opens the login terminal, and an honest
    /// note that credentials never touch the app.
    private var appleAccountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Apple 账号").font(.system(size: 15, weight: .semibold))
            HStack {
                Text(model.wrapperReady ? "下载服务已就绪" : model.connectionDetail)
                    .foregroundStyle(model.wrapperReady ? Paint.green : Paint.secondary)
                Spacer()
                Button("检查状态") { Task { await model.checkService() } }
                    .disabled(model.checkingService)
                Button("登录 Apple 账号") { model.openAppleLogin() }
            }
            Text("下载 Apple Music 要先用 Apple 账号登录一次。点登录会打开终端，账号、密码和验证码只在终端里输给 Apple，Music Bridge 不保存；登录完成回到这里，状态会自动变绿。")
                .font(.system(size: 12)).foregroundStyle(Paint.secondary).lineSpacing(3)
            if let note = model.appleLoginNote {
                Text(note).font(.system(size: 12, weight: .medium)).foregroundStyle(Paint.blue).lineSpacing(3)
            }
            if model.componentsMissing {
                Button(model.provisioning ? "正在备齐组件…" : "一键备齐组件") { model.provisionComponents() }
                    .disabled(model.provisioning)
            }
        }
        .padding(23)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }

    /// Full sign-in section for the settings page; the sidebar account
    /// row is the compact everyday version of the same state.
    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("网易云账号").font(.system(size: 15, weight: .semibold))
            if let name = model.neteaseNickname {
                HStack {
                    Text("\(name)（\(model.neteaseIsVIP ? "黑胶 VIP" : "普通账号")）")
                    Spacer()
                    Button("退出登录") { model.logoutNetease() }
                }
            } else {
                HStack {
                    Text("未登录").foregroundStyle(Paint.secondary)
                    Spacer()
                    Button("扫码登录") { model.startNeteaseLogin() }
                }
            }
            Text("登录保存在本机。黑胶 VIP 可直下付费与无损；普通账号仅免费曲目。")
                .font(.system(size: 12)).foregroundStyle(Paint.secondary).lineSpacing(3)
        }
        .padding(23)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingSurface()
    }

    private var disclosures: some View {
        VStack(spacing: 0) {
            // The two choices most people actually make stay visible. The
            // account lives in the sidebar; everything else is behind
            // 高级设置.
            VStack(alignment: .leading, spacing: 14) {
                Picker("下载音质", selection: $model.quality) {
                    ForEach(AudioQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                Picker("下载通道", selection: $model.downloadStrategy) {
                    Text("Apple 优先").tag(DownloadStrategy.appleFirst)
                    Text("网易云优先").tag(DownloadStrategy.neteaseFirst)
                }
                .pickerStyle(.menu)
                Text("网易云歌单按 ID 直下，拿不到的回落 Apple 匹配。")
                    .font(.system(size: 12)).foregroundStyle(Paint.secondary)
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            Rectangle().fill(Paint.line).frame(height: 1)
            DisclosureHeaderRow(title: "高级设置", detail: "封面 · 备用源 · 连接 · 文件", expanded: advancedExpanded) {
                advancedExpanded.toggle()
            }
            if advancedExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle("嵌入原始封面", isOn: $model.originalCover).tint(Paint.blue)
                    Toggle("iPod 封面统一 256px", isOn: $model.ipodCover256).tint(Paint.blue)
                    Text("导入时把同名封面压到 256px；iPod 封面来源需选「优先图片文件」。")
                        .foregroundStyle(Paint.secondary)
                    Toggle("Apple 没货时用网易云备用源补下", isOn: $model.fallbackEnabled).tint(Paint.blue)
                    Text("按原歌单 ID 直下网易云原曲；有黑胶 VIP 可达无损。来源记入账本与日志。")
                        .foregroundStyle(Paint.secondary)
                    HStack {
                        Text("连接状态").foregroundStyle(Paint.white)
                        Spacer()
                        Text(model.connectionDetail).foregroundStyle(Paint.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("检查连接") { Task { await model.checkService() } }
                            .disabled(model.checkingService)
                    }
                    actionRow("在 Finder 中显示下载目录") { NSWorkspace.shared.open(model.root) }
                    actionRow("导出当前歌单到文件夹…") { model.exportCurrentPlaylist() }
                        .disabled(model.selectedPlaylist == nil)
                    actionRow("重建媒体库（清除旧专辑条目）", destructive: true) { model.rebuildMediaLibrary() }
                        .disabled(!model.canImport || model.device?.isRockbox != true)
                    Text("先备份旧索引；随后需在 iPod「数据库」初始化。音乐文件保留。")
                        .foregroundStyle(Paint.secondary)
                }
                .font(.system(size: 12)).padding(.horizontal, 20).padding(.bottom, 20)
                .disabled(model.busy || model.importing)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -5)))
            }
        }
        .floatingSurface()
    }

    /// The run log is a diagnostic: it belongs with the configuration on
    /// the settings page, collapsed by default.
    private var logCard: some View {
        VStack(spacing: 0) {
            DisclosureHeaderRow(title: "运行日志", detail: "\(model.logs.count) 条", expanded: model.logsExpanded) { model.logsExpanded.toggle() }
            if model.logsExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in Text(line).frame(maxWidth: .infinity, alignment: .leading) }
                    }.textSelection(.enabled)
                }
                .font(.system(size: 12)).foregroundStyle(Paint.secondary)
                .frame(height: 140).padding(.horizontal, 20).padding(.bottom, 20)
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : -5)))
            }
        }
        .floatingSurface()
    }

    /// Settings action row: label on the left, chevron on the right,
    /// the whole row is the tap target — the same row language as the
    /// pickers and toggles around it. Destructive actions read red.
    private func actionRow(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(destructive ? Color.red : Paint.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Paint.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Section header shared by the settings disclosures and the download
/// page's review card: title, a quiet detail, a rotating chevron.
struct DisclosureHeaderRow: View {
    let title: String
    let detail: String
    let expanded: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(detail).font(.system(size: 11)).foregroundStyle(Paint.secondary)
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: detail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Paint.secondary).padding(.leading, 10)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: expanded)
            }.padding(.horizontal, 20).frame(height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }
}
