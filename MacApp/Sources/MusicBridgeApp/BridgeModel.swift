import AppKit
import CryptoKit
import SwiftUI

enum PlaylistSource: Equatable {
    case apple, netease, qq, kugou

    static func extractURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expression = try? NSRegularExpression(pattern: "https?://[^\\s<>\"，。！？）]+")
        for match in expression?.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) ?? [] {
            guard let range = Range(match.range, in: trimmed) else { continue }
            let raw = String(trimmed[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;!?)"))
            if let url = URL(string: raw), let host = url.host?.lowercased(),
               ["music.163.com", "163cn.tv", "music.apple.com", "itunes.apple.com",
                "y.qq.com", "i.y.qq.com", "i2.y.qq.com",
                "www.kugou.com", "m.kugou.com", "kugou.com"].contains(host),
               url.user == nil, url.password == nil {
                if host == "itunes.apple.com",
                   var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    components.host = "music.apple.com"
                    if let normalized = components.url { return normalized }
                }
                return url
            }
        }
        return nil
    }

    static func identify(_ text: String) -> PlaylistSource? {
        guard let url = extractURL(text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return nil }
        if host == "music.apple.com", url.path.contains("/playlist/"),
           url.pathComponents.contains(where: { $0.hasPrefix("pl.") && $0.count > 3 }) { return .apple }
        if host == "music.apple.com", isAppleSongURL(url) { return .apple }
        if host == "music.163.com", ["playlist", "album", "song"].contains(where: { url.path.contains($0) || (url.fragment ?? "").contains($0) }) { return .netease }
        if host == "163cn.tv" { return .netease }
        if ["y.qq.com", "i.y.qq.com", "i2.y.qq.com"].contains(host),
           url.path.contains("playlist") || url.path.contains("playsquare") { return .qq }
        if host.hasSuffix("kugou.com"), url.path.contains("/special/") { return .kugou }
        return nil
    }

    /// An Apple Music song link: either the /song/ form, or an album
    /// link whose ?i= query names the track. An album link without
    /// ?i= stays unrecognized — a whole album is not a single.
    static func isAppleSongURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "music.apple.com" else { return false }
        if url.path.contains("/song/") { return true }
        guard url.path.contains("/album/") else { return false }
        return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .contains { $0.name == "i" && !($0.value ?? "").isEmpty }
    }
}

/// One skipped song with the closest catalog candidate the matcher
/// rejected, presented in the review list for a manual decision.
struct ReviewableSkip: Identifiable, Equatable {
    let id: String
    let jobID: String
    let entryIndex: Int
    let title: String
    let artist: String
    let candidateTitle: String
    let candidateArtist: String
    let candidateAlbum: String?
    let reason: String
    let score: Double
}

/// Which download channel a run tries first. Apple-first keeps the
/// long-standing behaviour (catalog matching; NetEase only fills gaps).
/// NetEase-first downloads straight from NetEase by track ID under the
/// signed-in account's entitlements, and Apple matching fills the gaps.
enum DownloadStrategy: String {
    case appleFirst, neteaseFirst
}

@MainActor
final class BridgeModel: ObservableObject {
    @Published var source = ""
    @Published private(set) var selectedPlaylist: PlaylistSelection?
    private var pendingPlaylist: PlaylistSelection?
    private var downloadIssue: String?
    @Published var busy = false
    @Published var importing = false
    @Published var phase = "待开始"
    @Published var taskTitle = "没有活动任务"
    @Published var taskDetail = "下载完成后不会自动导入设备"
    @Published var percent = 0.0
    @Published var queue: Int?
    @Published var completed = 0
    @Published var skipped = 0
    @Published var failed = false
    @Published var settingsExpanded = false
    @Published var logsExpanded = false
    @Published var reviewsExpanded = false
    @Published private(set) var reviewableSkips: [ReviewableSkip] = []
    @Published var logs = ["Music Bridge 已就绪"]
    @Published var device: IPodDevice?
    @Published private(set) var availableDevices: [IPodDevice] = []
    @Published private(set) var selectedDeviceKey = ""
    @Published private(set) var checkingDevice = false
    @Published private(set) var loadingLocalState = false
    @Published var importMode: IPodImportMode = .automatic
    @Published var nativePresentation: NativeImportPresentation?
    @Published var rockboxPreview: RockboxImportPreview?
    @Published var compatibilityDetails = false
    @Published var nativeSelectedIDs = Set<String>()
    @Published var selectedProfileID = IPodKnowledge.defaultImportProfileID
    @Published var nativeInitializationAcknowledged = false
    @Published var nativePlaybackIssue = ""
    @Published var nativeTask: NativeImportTask? {
        didSet {
            if let task = nativeTask {
                nativeTaskWriter.enqueue(task, root: root) { [weak self] message in
                    Task { @MainActor in self?.log("任务记录未保存：" + message) }
                }
            }
        }
    }
    private var userConfirmedModels: [String: String] = [:]
    var nativePlan: NativeImportPlan? {
        get { if case .plan(let p) = nativePresentation { return p }; return nil }
        set { nativePresentation = newValue.map { .plan($0) } }
    }
    var nativeReview: NativeConversionReview? {
        get { if case .conversion(let r) = nativePresentation { return r }; return nil }
        set { nativeSelectedIDs = []; nativePresentation = newValue.map { .conversion($0) } }
    }
    @Published private(set) var deviceIOFailure = false
    @Published var wrapperReady = false
    @Published var checkingService = false
    @Published var connectionDetail = "尚未检查本地服务"
    @Published private(set) var neteaseNickname: String?
    @Published private(set) var neteaseIsVIP = false
    @Published private(set) var neteaseQRImage: NSImage?
    @Published private(set) var neteaseLoginPhaseText = ""
    private var neteaseCookieHeader: String?
    private var neteaseLoginTask: Task<Void, Never>?
    @Published var originalCover: Bool {
        didSet { preferences.set(originalCover, forKey: "originalCover") }
    }
    @Published var ipodCover256: Bool {
        didSet { preferences.set(ipodCover256, forKey: "ipodCover256") }
    }
    /// True once the Apple download service has ever reported ready on
    /// this machine; the first-run login guidance keys off it.
    @Published private(set) var appleServiceSeenReady = false
    /// Last outcome of an Apple login attempt, shown right where the
    /// login buttons live (settings card and download banner) so a
    /// click can never fail silently onto another page.
    @Published private(set) var appleLoginNote: String?
    /// True when the downloader or the wrapper is not in place yet;
    /// the login surfaces then offer one-tap provisioning instead of
    /// sending the user off to fetch files by hand.
    @Published private(set) var componentsMissing = false
    /// True while the components pack is being downloaded or laid down.
    @Published private(set) var provisioning = false
    private var provisionTask: Task<Void, Never>?
    @Published var fallbackEnabled: Bool {
        didSet { preferences.set(fallbackEnabled, forKey: "fallbackSourceEnabled") }
    }
    @Published var downloadStrategy: DownloadStrategy {
        didSet { preferences.set(downloadStrategy.rawValue, forKey: "downloadStrategy") }
    }
    @Published var quality: AudioQuality {
        didSet { preferences.set(quality.rawValue, forKey: "audioQuality") }
    }

    let root: URL
    private let runner = DownloaderRunner()
    private let importer = IPodImporter()
    private var workflow: Task<Void, Never>?
    private var observations: [NSObjectProtocol] = []
    private var generation = UUID()
    private var snapshot: [URL: FileSignature] = [:]
    private var progressMonitor: Task<Void, Never>?
    private var downloadJob: DownloadJob?
    /// Why NetEase could not serve a track in NetEase-first mode, keyed by
    /// track ID, so wrap-up can annotate the ledger instead of retrying a
    /// download that cannot succeed.
    private var neteasePrefetchNotes: [String: String] = [:]
    private var jobCurrentIndex: Int?
    private var jobBaseline: [URL: FileSignature] = [:]
    private var songWatchdog: Task<Void, Never>?
    private var appleLoginPoll: Task<Void, Never>?
    private var appleServiceProcess: Process?
    private var songTimedOut = false
    private var lastDownloadActivity = Date()
    private let preferences: UserDefaults
    private let deviceProvider: () -> [IPodDevice]
    private let usesSystemDeviceProvider: Bool
    private let nativeTaskWriter = NativeTaskWriter()
    private var deviceScan: Task<Void, Never>?
    private var deviceScanToken = UUID()
    private var localStateRestore: Task<Void, Never>?
    private var localStateRestoreToken = UUID()
    private var projectAccessURL: URL?
    private var deviceTimer: Timer?
    private var shutDown = false

    init(root: URL, preferences: UserDefaults = .standard,
         deviceProvider: (() -> [IPodDevice])? = nil,
         monitorDevices: Bool = true) {
        self.root = root
        self.preferences = preferences
        self.deviceProvider = deviceProvider ?? { IPodImporter().mountedDevices() }
        usesSystemDeviceProvider = deviceProvider == nil
        originalCover = preferences.object(forKey: "originalCover") as? Bool ?? true
        ipodCover256 = preferences.object(forKey: "ipodCover256") as? Bool ?? true
        appleServiceSeenReady = preferences.bool(forKey: "appleServiceWasReady")
        fallbackEnabled = preferences.object(forKey: "fallbackSourceEnabled") as? Bool ?? true
        downloadStrategy = DownloadStrategy(rawValue: preferences.string(forKey: "downloadStrategy") ?? "") ?? .appleFirst
        // Default to the 48 kHz lossless tier: higher sample rates stutter on
        // the iPod Classic, so Hi-Res is an explicit choice, never the default.
        quality = AudioQuality(rawValue: preferences.string(forKey: "audioQuality") ?? "") ?? .lossless
        neteaseCookieHeader = preferences.string(forKey: "neteaseCookieHeader")
        neteaseNickname = preferences.string(forKey: "neteaseNickname")
        neteaseIsVIP = (preferences.object(forKey: "neteaseVipType") as? Int ?? 0) > 0
        if !usesSystemDeviceProvider {
            selectedPlaylist = PlaylistLibrary(root: root).load()
            nativeTask = NativeImportTask.load(root: root)
            nativePlaybackIssue = nativeTask?.playbackIssue ?? ""
            if let selectedPlaylist { source = selectedPlaylist.sourceURL.absoluteString }
        }
        runner.onOutput = { [weak self] line in self?.receive(line) }
        runner.onStarted = { [weak self] in
            self?.phase = "正在下载"
            self?.taskTitle = "正在下载音乐"
            self?.monitorDownloadedFiles()
        }
        runner.onFinished = { [weak self] status in self?.finished(status) }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observations.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.requestDeviceRefresh() }
            })
        }
        requestDeviceRefresh()
        if usesSystemDeviceProvider {
            restoreLocalRecords()
        }
        if monitorDevices {
            deviceTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.requestDeviceRefresh() }
            }
        }
        if neteaseCookieHeader != nil {
            Task { @MainActor in await self.refreshNeteaseAccount() }
        }
        Task { @MainActor in await self.checkService() }
    }

    var canImport: Bool { device?.canImport == true && !deviceIOFailure && !loadingLocalState && !busy && !importing && !shutDown }
    var resolvedImportMode: IPodImportMode? { device?.resolvedMode(importMode) }
    var needsNativeInitialization: Bool {
        guard let device, !device.hasNativeDatabase, !device.hasCompressedNativeDatabase, !device.nativeDatabaseUnreadable else { return false }
        return importMode == .native || (importMode == .automatic && !device.isRockbox)
    }
    var importActionTitle: String {
        if importing { return "正在导入" }
        if needsNativeInitialization { return "建立原生音乐库" }
        switch resolvedImportMode {
        case .rockbox: return "Rockbox 导入"
        case .native: return "预览原生导入"
        default: return "开始导入"
        }
    }
    var importHint: String {
        if loadingLocalState { return "正在读取本地歌单记录；系统文件访问等待不会阻塞窗口。" }
        if device == nil { return availableDevices.isEmpty ? "连接设备后读取实际曲库与设备信息；普通存储盘不会作为 iPod。" : "请选择要导入的设备，不会自动切换到其他设备。" }
        let requestingNative = importMode == .native || (importMode == .automatic && device?.isRockbox == false)
        if requestingNative && device?.identity.nativeFamilyUnsupported == true { return "该机型暂未适配原生曲库写入；已识别的 Rockbox 导入路径仍可使用。" }
        if requestingNative && device?.nativeDatabaseUnreadable == true { return "原生数据库未通过读取检查；保留设备数据，请重新连接或恢复曲库。" }
        if requestingNative && device?.hasCompressedNativeDatabase == true && device?.hasNativeDatabase == false { return "检测到压缩原生曲库，当前写入未适配；不会重新初始化。" }
        if needsNativeInitialization { return "尚未建立原生曲库。核对机型后，备份并初始化即可开始导入。" }
        guard let mode = resolvedImportMode else { return "设备未检测到所选音乐库，请切换导入方式。" }
        if mode == .native {
            if device?.identity.permitsNativeImport != true { return "具体机型待确认或未适配，请查看兼容详情。" }
            if NativeIPodImporter(root: root).engineURL() == nil { return "需要 podkit 0.6.0；安装方法见 README。" }
            return "先处理同规格歌曲，剩余项最后选择转换；保留最高规格原文件。"
        }
        if device?.hasNativeDatabase == true && importMode == .automatic {
            return "检测到双系统文件，默认 Rockbox；可手动选择原生导入。"
        }
        return selectedPlaylist.map { "按歌单导入：\($0.name) · 保留原专辑信息" }
            ?? "按原专辑导入本地歌曲；下载后由你决定何时导入。"
    }

    var deviceStatus: String {
        guard let device else { return checkingDevice && availableDevices.isEmpty ? "正在识别" : availableDevices.isEmpty ? "等待连接" : "请选择设备" }
        if deviceIOFailure { return "读写异常" }
        if importing { return "正在导入" }
        switch device.writeState {
        case .writable: return "已挂载"
        case .readOnly: return "设备只读"
        case .unknown: return "权限待确认"
        }
    }

    func refreshDevice() {
        guard !shutDown else { return }
        deviceScanToken = UUID(); deviceScan?.cancel(); checkingDevice = false
        applyDevices(deviceProvider())
    }

    func requestDeviceRefresh() {
        guard !shutDown else { return }
        guard usesSystemDeviceProvider else { refreshDevice(); return }
        guard !checkingDevice else { return }
        checkingDevice = true
        let token = UUID(); deviceScanToken = token
        deviceScan = Task {
            let devices = await Task.detached(priority: .utility) { IPodImporter().mountedDevices() }.value
            guard !Task.isCancelled, !shutDown, deviceScanToken == token else { return }
            checkingDevice = false; applyDevices(devices)
        }
    }

    func selectDevice(_ key: String) {
        guard !busy, !importing else { return }
        selectedDeviceKey = key
        applyDevices(availableDevices)
    }

    private func applyDevices(_ devices: [IPodDevice]) {
        if availableDevices != devices { availableDevices = devices }
        if selectedDeviceKey.isEmpty, devices.count == 1 { selectedDeviceKey = devices[0].selectionKey }
        var detected = devices.first(where: { $0.selectionKey == selectedDeviceKey })
        if let uuid = detected?.volumeIdentifier, detected?.identity.profileID == nil, detected?.identity.conflict == false {
            detected?.identity.userConfirmedProfileID = userConfirmedModels[uuid]
        }
        if device != detected {
            if device?.rootURL != detected?.rootURL || device?.volumeIdentifier != detected?.volumeIdentifier {
                importMode = .automatic
                nativePlan = nil
                deviceIOFailure = false
            }
            device = detected
        }
    }

    func recheckDeviceFiles() {
        guard !busy, !importing, let target = device else { requestDeviceRefresh(); return }
        importing = true; taskDetail = "正在重新读取设备目录；不写入测试文件"
        workflow = Task {
            do {
                try await Task.detached(priority: .utility) {
                    try IPodImporter().validateFilesystem(on: target)
                }.value
                importing = false; refreshDevice()
                guard device?.matchesImportTarget(target) == true else { throw NativeImportError.invalidDevice }
                deviceIOFailure = false; taskDetail = "设备目录读取通过；写入将在导入时核对。"
            } catch {
                importing = false; deviceIOFailure = true
                fail("设备目录检查未通过", error.localizedDescription)
            }
        }
    }

    func confirmUserModel() {
        guard !busy, !importing, var current = device, let uuid = current.volumeIdentifier,
              current.identity.allowsManualProfile(selectedProfileID) else { return }
        userConfirmedModels[uuid] = selectedProfileID
        current.identity.userConfirmedProfileID = selectedProfileID
        device = current; nativePresentation = nil
        log("本次会话按用户确认的型号规划；原始识别信息保留，未修改设备。")
    }

    func revealOriginal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func restoreLocalRecords() {
        guard !shutDown, !busy, !importing else { return }
        localStateRestore?.cancel()
        let token = UUID(), directory = root
        localStateRestoreToken = token; loadingLocalState = true
        taskDetail = "正在后台读取本地记录；若等待较久，可选择项目文件夹来确认文件访问。"
        localStateRestore = Task {
            let saved = await Task.detached(priority: .utility) {
                (PlaylistLibrary(root: directory).load(), NativeImportTask.load(root: directory))
            }.value
            guard !Task.isCancelled, !shutDown, localStateRestoreToken == token else { return }
            if source.isEmpty || source == saved.0?.sourceURL.absoluteString {
                selectedPlaylist = saved.0
                if let selection = saved.0 { source = selection.sourceURL.absoluteString }
            }
            nativeTask = saved.1; nativePlaybackIssue = saved.1?.playbackIssue ?? ""
            loadingLocalState = false
            if phase == "待开始" { taskDetail = "本地记录已读取；下载完成后不会自动导入设备。" }
        }
    }

    func chooseProjectAccess() {
        guard !busy, !importing else { return }
        let panel = NSOpenPanel()
        panel.title = "选择 Music Bridge 项目文件夹"
        panel.message = "仅选择当前项目文件夹，用于读取歌单记录与下载音乐。"
        panel.prompt = "读取此项目"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self, response == .OK, let url = panel.url else { return }
                guard url.standardizedFileURL.path == self.root.standardizedFileURL.path else {
                    self.fail("请选择当前项目文件夹", self.root.path); return
                }
                self.projectAccessURL?.stopAccessingSecurityScopedResource()
                self.projectAccessURL = nil
                if url.startAccessingSecurityScopedResource() { self.projectAccessURL = url }
                self.restoreLocalRecords()
            }
        }
    }

    func initializeNativeLibrary(_ request: NativeInitializationRequest) {
        guard nativeInitializationAcknowledged, canImport, device?.matchesImportTarget(request.device) == true else { return }
        let target = request.device, profile = selectedProfileID, directory = root, session = generation
        nativePresentation = nil; importing = true; failed = false; percent = 0
        phase = "初始化原生曲库"; taskTitle = "正在备份设备信息"
        workflow = Task { [self] in
            do {
                let backup = try await Task.detached(priority: .userInitiated) {
                    try NativeLibraryService(root: directory).initialize(target, profileID: profile) { detail in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == session, !self.shutDown else { return }
                            self.taskDetail = detail
                        }
                    }
                }.value
                guard generation == session, !shutDown else { return }
                importing = false; refreshDevice(); importMode = .native
                percent = 100; phase = "原生曲库已建立"; taskTitle = "空曲库已回读确认"
                taskDetail = "下一步预览所选歌单；初始化配置与实际设备记录分别显示。"
                log("原生曲库初始化完成；设备信息备份：" + backup.path)
            } catch {
                guard generation == session, !shutDown else { return }
                importing = false; refreshDevice(); fail("原生曲库初始化未完成", error.localizedDescription)
            }
        }
    }

    var canEjectNative: Bool {
        guard !busy, !importing, nativePresentation == nil, let task = nativeTask, task.writeVerified,
              !task.ejected, let device, let uuid = task.deviceUUID else { return false }
        return device.volumeIdentifier == uuid && device.rootURL == task.deviceRoot
    }

    func ejectNativeDevice() {
        refreshDevice()
        guard canEjectNative, let target = device else { return }
        let directory = root
        importing = true; taskDetail = "正在请求系统安全弹出 iPod"
        workflow = Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try NativeLibraryService(root: directory).validateMount(target)
                    try NSWorkspace.shared.unmountAndEjectDevice(at: target.rootURL)
                }.value
                importing = false
                if nativeTask?.deviceUUID == target.volumeIdentifier {
                    nativeTask?.ejected = true
                    nativeTask?.stage = "已安全弹出，等待实机检查"
                }
                taskDetail = "请在 iPod 原生菜单检查歌单、封面及播放，再记录结果。"
                refreshDevice()
            } catch {
                importing = false; fail("未能安全弹出", error.localizedDescription)
            }
        }
    }

    func recordNativePlayback(success: Bool) {
        guard nativeTask?.ejected == true else { return }
        nativeTask?.playback = success ? "用户已确认实机播放正常" : "实机反馈有问题"
        nativeTask?.stage = success ? "导入与用户实机确认完成" : "设备写入已核对，等待排查实机问题"
    }

    var canConfirmExternalEjection: Bool {
        guard !busy, !importing, let task = nativeTask, task.writeVerified, !task.ejected else { return false }
        return !FileManager.default.fileExists(atPath: task.deviceRoot.path)
    }

    func confirmExternalEjection() {
        guard canConfirmExternalEjection else { return }
        nativeTask?.ejected = true
        nativeTask?.stage = "用户确认已在系统中安全弹出，等待实机检查"
    }

    func saveNativePlaybackIssue() { nativeTask?.playbackIssue = String(nativePlaybackIssue.prefix(2000)) }

    private func updateNativeProgress(_ detail: String) {
        taskDetail = detail; nativeTask?.stage = detail
        if let range = detail.range(of: "[0-9]+ / [0-9]+", options: .regularExpression) {
            let parts = detail[range].split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[1] > 0 { percent = min(90, 10 + parts[0] / parts[1] * 65) }
        } else if detail.contains("备份") { percent = 78 }
        else if detail.contains("复制") { percent = 82 }
        else if detail.contains("回读") || detail.contains("重新读取") { percent = 90 }
        else if detail.contains("播放列表") { percent = 95 }
    }

    // MARK: NetEase account

    func startNeteaseLogin() {
        guard !shutDown else { return }
        neteaseLoginTask?.cancel()
        neteaseLoginPhaseText = "正在生成二维码…"
        neteaseLoginTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = NeteaseAccountClient()
                let qr = try await client.createLoginQR()
                guard !Task.isCancelled, !shutDown else { return }
                neteaseQRImage = qr.image
                neteaseLoginPhaseText = "请用网易云音乐 App 扫码登录"
                var confirmedPolls = 0
                var lastPollDebug = ""
                for _ in 0..<110 {
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                    guard !Task.isCancelled, !shutDown else { return }
                    let poll = await client.pollLogin(key: qr.key)
                    if poll.debug != lastPollDebug {
                        lastPollDebug = poll.debug
                        log("网易云登录\(poll.debug)")
                    }
                    switch poll.result {
                    case .waiting:
                        continue
                    case .scanned:
                        neteaseLoginPhaseText = "已扫码，请在手机上确认登录"
                    case .confirmed:
                        confirmedPolls += 1
                        neteaseLoginPhaseText = "已在手机确认，正在完成登录…"
                        if confirmedPolls >= 4 {
                            neteaseQRImage = nil
                            neteaseLoginPhaseText = ""
                            log("手机已确认，但网易云没有把登录会话发回来；请取消后重新扫码。若反复出现，把这条日志告诉小包包。")
                            return
                        }
                    case .expired:
                        neteaseQRImage = nil
                        neteaseLoginPhaseText = ""
                        log("网易云登录二维码已过期，请重新点扫码登录。")
                        return
                    case .blocked(let message):
                        neteaseQRImage = nil
                        neteaseLoginPhaseText = ""
                        log("网易云登录被风控拦截：\(message)。可以先在这台 Mac 的浏览器里登录一次 music.163.com 再回来扫码，或稍后再试。")
                        return
                    case .success(let cookie):
                        neteaseCookieHeader = cookie
                        preferences.set(cookie, forKey: "neteaseCookieHeader")
                        neteaseQRImage = nil
                        neteaseLoginPhaseText = ""
                        await refreshNeteaseAccount()
                        return
                    }
                }
                neteaseQRImage = nil
                neteaseLoginPhaseText = ""
                log("网易云登录超时，请重试。")
            } catch {
                if error is CancellationError { return }
                guard !Task.isCancelled, !shutDown else { return }
                neteaseQRImage = nil
                neteaseLoginPhaseText = ""
                log("网易云登录失败：\(error.localizedDescription)")
            }
        }
    }

    func cancelNeteaseLogin() {
        neteaseLoginTask?.cancel()
        neteaseQRImage = nil
        neteaseLoginPhaseText = ""
    }

    func logoutNetease() {
        cancelNeteaseLogin()
        neteaseCookieHeader = nil
        neteaseNickname = nil
        neteaseIsVIP = false
        preferences.removeObject(forKey: "neteaseCookieHeader")
        preferences.removeObject(forKey: "neteaseNickname")
        preferences.removeObject(forKey: "neteaseVipType")
        log("已退出网易云登录。")
    }

    func refreshNeteaseAccount() async {
        guard let cookie = neteaseCookieHeader, !cookie.isEmpty else { return }
        do {
            let profile = try await NeteaseAccountClient().fetchProfile(cookieHeader: cookie)
            neteaseNickname = profile.nickname
            neteaseIsVIP = profile.isVIP
            preferences.set(profile.nickname, forKey: "neteaseNickname")
            preferences.set(profile.vipType, forKey: "neteaseVipType")
            log("网易云已登录：\(profile.nickname)（\(profile.isVIP ? "黑胶 VIP" : "普通账号")）；网易云通道将按此账号权益取流。")
        } catch {
            log("网易云登录状态校验失败（登录可能已过期）：\(error.localizedDescription)")
        }
    }

    func checkService() async {
        guard !checkingService, !shutDown else { return }
        checkingService = true
        defer { checkingService = false }
        // Component self-check first: a live wrapper is useless if the
        // downloader binary or its launcher is missing from the folder.
        let files = FileManager.default
        var missing: [String] = []
        if !files.isExecutableFile(atPath: root.appendingPathComponent("amdl").path) { missing.append("下载器 amdl") }
        if !files.fileExists(atPath: root.appendingPathComponent("work/wrapper-lite-macos/start-local.sh").path) { missing.append("解密服务启动脚本") }
        componentsMissing = !missing.isEmpty || !files.fileExists(atPath: root.appendingPathComponent("work/wrapper-lite-macos/login-local.sh").path)
        if !missing.isEmpty {
            wrapperReady = false
            connectionDetail = "组件缺失：\(missing.joined(separator: "、"))"
            if appleLoginNote == nil,
               !files.fileExists(atPath: root.appendingPathComponent("work/wrapper-lite-macos/login-local.sh").path) {
                appleLoginNote = "没找到登录组件：Music Bridge 的仓库不含 wrapper 本体，需要先按 README 的「配置下载」一节，把 wrapper-lite 放到项目文件夹的 work/wrapper-lite-macos 里，再回来点登录。"
            }
            return
        }
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:12340/status")!)
            request.timeoutInterval = 2
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !shutDown else { return }
            let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            wrapperReady = (response as? HTTPURLResponse)?.statusCode == 200 && (status?["code"] as? Int) == 0
            if wrapperReady { appleLoginNote = nil }
            if wrapperReady, !appleServiceSeenReady {
                appleServiceSeenReady = true
                preferences.set(true, forKey: "appleServiceWasReady")
            }
            connectionDetail = wrapperReady ? "本地下载服务已就绪 · 组件齐全" : "服务响应异常；点击开始后将重试"
        } catch {
            guard !shutDown else { return }
            wrapperReady = false
            connectionDetail = "服务尚未启动；点击开始后自动启动"
            if appleLoginNote == nil,
               !FileManager.default.fileExists(atPath: root.appendingPathComponent("work/wrapper-lite-macos/login-local.sh").path) {
                appleLoginNote = "没找到登录组件：Music Bridge 的仓库不含 wrapper 本体，需要先按 README 的「配置下载」一节，把 wrapper-lite 放到项目文件夹的 work/wrapper-lite-macos 里，再回来点登录。"
            }
        }
    }

    /// Opens a Terminal window running the wrapper's interactive login
    /// script: Apple ID, password and any 2FA code are typed into the
    /// terminal and go only to Apple — the app never sees or stores
    /// them. A poll then starts the local service and watches /status
    /// until the fresh login reports ready.
    func openAppleLogin() {
        let wrapperDir = root.appendingPathComponent("work/wrapper-lite-macos")
        guard FileManager.default.fileExists(atPath: wrapperDir.appendingPathComponent("login-local.sh").path) else {
            appleLoginNote = "没找到登录组件：Music Bridge 的仓库不含 wrapper 本体，需要先按 README 的「配置下载」一节，把 wrapper-lite 放到项目文件夹的 work/wrapper-lite-macos 里，再回来点登录。"
            fail("找不到登录脚本", "work/wrapper-lite-macos/login-local.sh 不在项目文件夹里。")
            return
        }
        let commandURL = wrapperDir.appendingPathComponent("login-apple.command")
        let script = """
        #!/bin/zsh
        cd "\(wrapperDir.path)"
        ./login-local.sh
        echo ""
        echo "登录流程结束。回到 Music Bridge，状态变绿就能开始下载；这个窗口可以关掉。"
        """
        do {
            try script.write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)
        } catch {
            appleLoginNote = "登录脚本创建失败：\(error.localizedDescription)"
            fail("打不开登录终端", error.localizedDescription)
            return
        }
        guard NSWorkspace.shared.open(commandURL) else {
            appleLoginNote = "终端没能打开。请检查终端 App 是否可用，或手动双击项目文件夹里 work/wrapper-lite-macos/login-apple.command 完成登录。"
            fail("打不开登录终端", "系统未能打开 login-apple.command。")
            return
        }
        appleLoginNote = "终端已打开：在终端里输 Apple ID 和密码；如果 Apple 要二次验证，验证码由 Apple 发送到该账号的受信任设备或绑定的手机号，把收到的验证码输回终端即可。完成后回到这里，状态会自动变绿。"
        log("已打开终端进行 Apple 登录：在终端里输入 Apple ID、密码和验证码，完成后回到这里。")
        appleLoginPoll?.cancel()
        appleLoginPoll = Task { [weak self] in
            var serviceKickDone = false
            for _ in 0..<60 {
                guard let self, !Task.isCancelled, !self.shutDown else { return }
                await self.checkService()
                if self.wrapperReady {
                    self.appleLoginNote = nil
                    self.log("Apple 登录完成，下载服务已就绪。")
                    return
                }
                if !serviceKickDone {
                    serviceKickDone = true
                    self.ensureAppleServiceRunning()
                }
                try? await Task.sleep(for: .seconds(5))
            }
            self?.appleLoginNote = "还没检测到登录完成；登好之后点「检查状态」，或直接开始下载。"
            self?.log("还没检测到登录完成；登好之后点「检查状态」，或直接开始下载。")
        }
    }

    /// Starts the local wrapper service when it is not already running,
    /// so a fresh login gets picked up without waiting for a download.
    /// A service the downloader started itself is left alone — the
    /// status probe sees it first.
    private func ensureAppleServiceRunning() {
        if appleServiceProcess?.isRunning == true { return }
        let startScript = root.appendingPathComponent("work/wrapper-lite-macos/start-local.sh")
        guard FileManager.default.fileExists(atPath: startScript.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [startScript.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            appleServiceProcess = process
        } catch {
            log("解密服务启动失败：\(error.localizedDescription)")
        }
    }

    /// Downloads the pristine components pack (downloader + wrapper,
    /// no login state) from the project's GitHub release and lays it
    /// down where the rest of the app expects it, so a fresh install
    /// needs no manual file hunting. The pack's SHA-256 is pinned in
    /// the source; a mismatch aborts before anything is moved. An
    /// existing login state (qemu/data.img) is preserved across a
    /// re-provision.
    func provisionComponents() {
        guard !provisioning else { return }
        provisioning = true
        appleLoginNote = "正在下载组件包…"
        provisionTask?.cancel()
        provisionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.downloadAndInstallComponents()
                self.provisioning = false
                self.appleLoginNote = "组件已备齐，现在点「登录 Apple 账号」就能登录了。"
                self.log("组件包已下载并安装完成。")
                await self.checkService()
            } catch {
                self.provisioning = false
                self.appleLoginNote = "组件没能备齐：\(error.localizedDescription)。检查网络后再点一次「一键备齐组件」。"
                self.log("组件安装失败：\(error.localizedDescription)")
            }
        }
    }

    private func downloadAndInstallComponents() async throws {
        let packURL = URL(string: "https://github.com/ZexinLiu725/music-bridge/releases/download/components-1/music-bridge-components.zip")!
        let expectedSHA256 = "119bec72eb1e3f6d661994ba3c3a5b9caa9be05513eb0ed215fcc20cbf8202dc"
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("music-bridge-components-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let zipURL = staging.appendingPathComponent("components.zip")
        let (downloaded, response) = try await URLSession.shared.download(from: packURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "MusicBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "组件包下载失败（服务器没有返回文件）"])
        }
        try fm.moveItem(at: downloaded, to: zipURL)
        appleLoginNote = "组件包下载完成，正在校验安装…"
        if !expectedSHA256.isEmpty, expectedSHA256 != "COMPONENTS_SHA256_PLACEHOLDER" {
            let digest = try sha256Hex(of: zipURL)
            guard digest == expectedSHA256 else {
                throw NSError(domain: "MusicBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "组件包校验不通过，已放弃安装"])
            }
        }
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipURL.path, extracted.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw NSError(domain: "MusicBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "组件包解压失败"])
        }
        let packedAmdl = extracted.appendingPathComponent("amdl")
        let packedWrapper = extracted.appendingPathComponent("wrapper-lite-macos")
        guard fm.fileExists(atPath: packedAmdl.path), fm.fileExists(atPath: packedWrapper.path) else {
            throw NSError(domain: "MusicBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "组件包内容不完整"])
        }
        let targetAmdl = root.appendingPathComponent("amdl")
        if fm.fileExists(atPath: targetAmdl.path) { try fm.removeItem(at: targetAmdl) }
        try fm.copyItem(at: packedAmdl, to: targetAmdl)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetAmdl.path)
        let workDir = root.appendingPathComponent("work", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let targetWrapper = workDir.appendingPathComponent("wrapper-lite-macos", isDirectory: true)
        let savedData = staging.appendingPathComponent("saved-data", isDirectory: true)
        try fm.createDirectory(at: savedData, withIntermediateDirectories: true)
        let liveData = targetWrapper.appendingPathComponent("qemu/data.img")
        let liveDataPrev = targetWrapper.appendingPathComponent("qemu/data.img.previous")
        let hadData = fm.fileExists(atPath: liveData.path)
        if hadData { try fm.copyItem(at: liveData, to: savedData.appendingPathComponent("data.img")) }
        if fm.fileExists(atPath: liveDataPrev.path) { try? fm.copyItem(at: liveDataPrev, to: savedData.appendingPathComponent("data.img.previous")) }
        if fm.fileExists(atPath: targetWrapper.path) { try fm.removeItem(at: targetWrapper) }
        try fm.copyItem(at: packedWrapper, to: targetWrapper)
        if hadData {
            let qemuDir = targetWrapper.appendingPathComponent("qemu", isDirectory: true)
            try fm.copyItem(at: savedData.appendingPathComponent("data.img"), to: qemuDir.appendingPathComponent("data.img"))
            let prev = savedData.appendingPathComponent("data.img.previous")
            if fm.fileExists(atPath: prev.path) { try? fm.copyItem(at: prev, to: qemuDir.appendingPathComponent("data.img.previous")) }
        }
    }

    private func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func startOrStop() {
        guard !importing, !loadingLocalState, !shutDown else { return }
        if busy { stop(); return }
        guard let platform = PlaylistSource.identify(source) else {
            fail("链接暂不识别", "可粘贴网易云、QQ 音乐、酷狗歌单链接、网易云专辑链接，以及网易云和 Apple Music 的单曲链接、Apple Music 公开歌单链接。")
            return
        }
        busy = true; failed = false; percent = 0; completed = 0; skipped = 0; queue = nil
        generation = UUID()
        let session = generation
        guard let link = PlaylistSource.extractURL(source) else { return }
        let text = link.absoluteString
        pendingPlaylist = nil
        downloadIssue = nil
        downloadJob = nil
        neteasePrefetchNotes = [:]
        jobCurrentIndex = nil
        phase = "正在准备"; taskTitle = "正在读取歌单"; taskDetail = "准备下载，完成后由你决定何时导入"
        workflow = Task { [self] in
            do {
                var earlySnapshotTaken = false
                if platform != .apple {
                    let export = try await GoMusicClient().exportPlaylist(url: text)
                    try Task.checkCancellation()
                    guard session == generation else { return }
                    guard let resolvedSelection = export.playlist else { throw PlaylistLibraryError.invalidPlaylist }
                    source = resolvedSelection.sourceURL.absoluteString
                    queue = export.count; phase = "正在匹配"; taskTitle = "正在匹配 Apple Music"
                    if var resumed = DownloadJobStore(root: root).load(id: resolvedSelection.id), resumed.finishedAt == nil {
                        // Pick up an interrupted job for this playlist: songs
                        // already on disk stay downloaded, the rest go back to
                        // pending (bounded by the attempt cap) and catalog
                        // matching is not repeated.
                        var pendingCount = 0
                        for index in resumed.entries.indices {
                            switch resumed.entries[index].state {
                            case .downloading:
                                resumed.entries[index].state = .pending; pendingCount += 1
                            case .failed, .timedOut:
                                if resumed.entries[index].attempts < 3 {
                                    resumed.entries[index].state = .pending; pendingCount += 1
                                }
                            case .pending:
                                pendingCount += 1
                            case .downloaded, .skipped:
                                break
                            }
                        }
                        if pendingCount > 0 {
                            downloadJob = resumed
                            pendingPlaylist = export.playlist
                            pendingPlaylist?.tracks = resumed.entries
                                .filter { $0.url != nil }
                                .map { PlaylistSong(title: $0.title, artist: $0.artist, album: $0.album) }
                            skipped = resumed.entries.filter { $0.state == .skipped }.count
                            queue = resumed.entries.filter { $0.url != nil }.count
                            let doneCount = resumed.entries.filter { $0.state == .downloaded }.count
                            persistJob()
                            refreshReviewable()
                            log("恢复未完成的下载任务：已完成 \(doneCount) 首，继续剩余 \(pendingCount) 首。")
                        }
                    }
                    if downloadJob == nil {
                        let result = try await AppleMusicCatalogClient().match(export: export) { [weak self] current, total in
                            guard let self, self.generation == session else { return }
                            self.taskDetail = "正在匹配 · \(current) / \(total)"
                        }
                        try Task.checkCancellation()
                        guard session == generation else { return }
                        skipped = result.skipped.count
                        pendingPlaylist = export.playlist
                        pendingPlaylist?.tracks = result.tracks
                        if !result.skipped.isEmpty { log("跳过 \(result.skipped.count) 首未确认版本的歌曲。") }
                        var entries = zip(result.tracks, result.urls).enumerated().map { offset, pair in
                            // Trace the matched entry back to its source track
                            // via the query that produced it, so the entry
                            // keeps the source-platform ID for direct fetch.
                            let query = offset < result.matchedQueries.count ? result.matchedQueries[offset] : nil
                            let sourceTrack = query.flatMap { q in
                                resolvedSelection.tracks.first { $0.title == q.title && $0.artist == q.artist }
                                    ?? resolvedSelection.tracks.first { $0.title == q.title }
                            }
                            return DownloadJobEntry(title: pair.0.title, artist: pair.0.artist, album: pair.0.album, url: pair.1, state: .pending,
                                                    neteaseID: sourceTrack?.neteaseID, platformID: pair.0.platformID)
                        }
                        entries += result.skipped.map { query in
                            let review = result.reviews.first { $0.query.title == query.title && $0.query.artist == query.artist }
                            let sourceTrack = resolvedSelection.tracks.first { $0.title == query.title && $0.artist == query.artist }
                                ?? resolvedSelection.tracks.first { $0.title == query.title }
                            return DownloadJobEntry(title: query.title, artist: query.artist, state: .skipped,
                                                    detail: review.map { "未确认版本（\($0.reason)）" } ?? "匹配阶段未确认版本",
                                                    review: review.map {
                                                        DownloadJobReview(title: $0.candidateTitle, artist: $0.candidateArtist,
                                                                          album: $0.candidateAlbum, url: $0.candidateURL,
                                                                          durationMs: $0.candidateDurationMs, score: $0.score,
                                                                          reason: $0.reason)
                                                    },
                                                    neteaseID: sourceTrack?.neteaseID, platformID: sourceTrack?.platformID)
                        }
                        downloadJob = DownloadJob(id: resolvedSelection.id, name: resolvedSelection.name,
                                                  sourceURL: text, createdAt: Date(), updatedAt: Date(), entries: entries)
                        queue = result.urls.count
                        persistJob()
                        refreshReviewable()
                        if downloadStrategy == .neteaseFirst {
                            if platform == .netease, neteaseCookieHeader != nil {
                                // Snapshot before fetching: wrap-up diffs the
                                // folder against this baseline, so anything
                                // fetched now must postdate it to be counted.
                                let fetchService = importer
                                let fetchDirectory = root
                                let earlyScan = Task.detached(priority: .utility) { fetchService.snapshotAudioFiles(in: fetchDirectory) }
                                let earlyFiles = await withTaskCancellationHandler(operation: { await earlyScan.value }, onCancel: { earlyScan.cancel() })
                                try Task.checkCancellation()
                                guard session == generation else { return }
                                snapshot = earlyFiles
                                earlySnapshotTaken = true
                                await prefetchNetease(session: session, selection: resolvedSelection)
                            } else {
                                log(platform == .netease ? "网易云优先未生效：尚未登录网易云，本次按 Apple 优先下载。" : "网易云优先仅对网易云歌单生效，本次按 Apple 优先下载。")
                            }
                        }
                    }
                } else {
                    let isSong = PlaylistSource.isAppleSongURL(link)
                    downloadJob = DownloadJob(id: "apple-\(UUID().uuidString)", name: isSong ? "Apple Music 单曲" : "Apple Music 歌单",
                                              sourceURL: text, createdAt: Date(), updatedAt: Date(),
                                              entries: [DownloadJobEntry(title: isSong ? "单曲" : "歌单", artist: "", url: text, state: .pending)])
                    queue = 1
                    persistJob()
                }
                try Task.checkCancellation()
                guard session == generation else { return }
                try applyDownloadSettings()
                let service = importer
                let directory = root
                let scan = Task.detached(priority: .utility) { service.snapshotAudioFiles(in: directory) }
                let files = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
                try Task.checkCancellation()
                guard session == generation else { return }
                if !earlySnapshotTaken { snapshot = files }
                phase = "正在连接"; taskTitle = "正在准备下载"
                taskDetail = "正在检查本地下载服务和登录状态"
                log("正在准备本地下载服务。")
                log("音质：\(quality.title)；实际规格以曲目提供的音源为准。")
                startNextJobSong(session: session)
            } catch {
                guard !Task.isCancelled, session == generation else { return }
                fail("下载没有完成", error.localizedDescription)
            }
        }
    }

    func stop() {
        guard !importing, !shutDown else { return }
        generation = UUID(); workflow?.cancel(); progressMonitor?.cancel(); songWatchdog?.cancel(); runner.stop()
        if var job = downloadJob, job.finishedAt == nil {
            for index in job.entries.indices where job.entries[index].state == .downloading {
                job.entries[index].state = .pending
            }
            job.updatedAt = Date()
            downloadJob = job
            persistJob()
        }
        jobCurrentIndex = nil
        busy = false; phase = "已停止"; taskTitle = "任务已停止"
        taskDetail = "已下载文件保留在电脑中"; log("任务已停止。")
    }

    private func applyDownloadSettings() throws {
        let configURL = root.appendingPathComponent("config.yaml")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let withCover = DownloadConfiguration.settingCover(originalCover, in: config)
        // amdl embeds synced lyrics itself when embed-lrc is on; pin it so a
        // hand-edited config cannot silently turn lyric embedding off.
        try DownloadConfiguration.settingEmbedLyrics(true, in: withCover).write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func receive(_ line: String) {
        guard busy else { return }
        lastDownloadActivity = Date()
        // Do not surface raw subprocess output: it may contain account/session values.
        if line.localizedCaseInsensitiveContains("temari library error") {
            downloadIssue = "下载器缺少可用的 Temari 动态库，尚未下载歌曲。"
        }
        if let range = line.range(of: "Track \\d+ of \\d+", options: .regularExpression) {
            let words = line[range].split(separator: " ")
            if let current = Int(words[1]), let total = Int(words[3]) {
                queue = total; taskDetail = "正在处理 · \(current) / \(total)"
            }
        }
        if let range = line.range(of: "(?<![0-9])\\d{1,3}%", options: .regularExpression),
           let value = Double(line[range].dropLast()) { percent = min(100, max(0, value)) }
        if line.localizedCaseInsensitiveContains("decrypting") { taskDetail = "正在封装音频" }
    }

    private func monitorDownloadedFiles() {
        progressMonitor?.cancel()
        let session = generation
        let directory = root
        let previous = snapshot
        let service = importer
        progressMonitor = Task { [weak self] in
            var stable: [URL: FileSignature] = [:]
            var verified: [URL: FileSignature] = [:]
            while !Task.isCancelled {
                let last = stable
                let checked = verified
                let scan = await Task.detached(priority: .utility) {
                    service.downloadProgress(in: directory, comparedTo: previous, lastScan: last, verified: checked)
                }.value
                guard !Task.isCancelled, let self, self.busy, self.generation == session else { return }
                stable = scan.current
                verified = scan.verified
                self.completed = verified.count
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// One amdl process now covers exactly one song, so an exit here ends a
    /// song, not the job: record the outcome in the ledger, then either
    /// start the next pending song or, when the queue drains, wrap up.
    private func finished(_ status: Int32) {
        guard busy else { return }
        songWatchdog?.cancel()
        guard downloadJob != nil, jobCurrentIndex != nil else { wrapUpDownload(); return }
        let session = generation
        let service = importer
        let directory = root
        let baseline = jobBaseline
        let timedOut = songTimedOut
        workflow = Task {
            let scan = Task.detached(priority: .utility) { service.changedAudioFiles(in: directory, comparedTo: baseline) }
            let changed = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled, session == generation, !shutDown else { return }
            if let downloadIssue { fail("下载未确认完成", downloadIssue); return }
            guard var job = downloadJob, let idx = jobCurrentIndex, job.entries.indices.contains(idx) else { wrapUpDownload(); return }
            if timedOut {
                job.entries[idx].state = .timedOut
                job.entries[idx].detail = "长时间无进展，已自动跳过"
                log("超时跳过：\(job.entries[idx].title)")
            } else if status != 0 {
                job.entries[idx].state = .failed
                job.entries[idx].detail = "下载器退出代码 \(status)"
                log("下载失败：\(job.entries[idx].title)（退出代码 \(status)）")
            } else if changed.isEmpty {
                job.entries[idx].state = .failed
                job.entries[idx].detail = "未发现新文件"
                log("下载失败：\(job.entries[idx].title)（未发现新文件）")
            } else {
                job.entries[idx].state = .downloaded
                job.entries[idx].detail = changed.map { $0.url.lastPathComponent }.joined(separator: "、")
            }
            job.updatedAt = Date()
            downloadJob = job
            persistJob()
            jobCurrentIndex = nil
            startNextJobSong(session: session)
        }
    }

    private func startNextJobSong(session: UUID) {
        guard session == generation, busy else { return }
        guard var job = downloadJob,
              let idx = job.entries.firstIndex(where: { $0.state == .pending }),
              let url = job.entries[idx].url else { wrapUpDownload(); return }
        job.entries[idx].state = .downloading
        job.entries[idx].attempts += 1
        job.updatedAt = Date()
        downloadJob = job
        persistJob()
        jobCurrentIndex = idx
        songTimedOut = false
        lastDownloadActivity = Date()
        let total = job.entries.filter { $0.url != nil }.count
        let done = job.entries.filter { $0.state == .downloaded }.count
        phase = "正在下载"
        taskTitle = job.name
        let entry = job.entries[idx]
        taskDetail = "正在下载 · \(done + 1) / \(total)：\(entry.title)" + (entry.artist.isEmpty ? "" : " · \(entry.artist)")
        let service = importer
        let directory = root
        workflow = Task {
            let scan = Task.detached(priority: .utility) { service.snapshotAudioFiles(in: directory) }
            let files = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard session == generation, busy, !Task.isCancelled else { return }
            jobBaseline = files
            runner.start(binaryPath: root.appendingPathComponent("amdl").path,
                         workingDirectory: root.path, urls: [url],
                         wrapperLauncherPath: root.appendingPathComponent("work/wrapper-lite-macos/start-local.sh").path,
                         wrapperURL: URL(string: "http://127.0.0.1:12340")!, quality: quality,
                         batchFolder: pendingPlaylist?.name) { [weak self] result in
                guard let self, self.generation == session else { return }
                if case .failure(let error) = result { self.fail("下载服务未就绪", error.localizedDescription) }
            }
            startSongWatchdog(session: session)
        }
    }

    /// A song that produces no downloader output for 150 seconds (or runs
    /// past 15 minutes in total) is treated as stalled: amdl is terminated
    /// for that song only, the ledger marks it timed out, and the queue
    /// moves on instead of freezing the whole playlist like before.
    private func startSongWatchdog(session: UUID) {
        songWatchdog?.cancel()
        let started = Date()
        songWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, self.generation == session, self.busy, self.jobCurrentIndex != nil else { return }
                let idle = Date().timeIntervalSince(self.lastDownloadActivity)
                // The total-runtime cap applies to single-song jobs only: an
                // Apple playlist arrives as one process for the whole list
                // and may legitimately run longer.
                let totalCapExceeded = self.pendingPlaylist != nil && Date().timeIntervalSince(started) > 900
                if idle > 150 || totalCapExceeded {
                    self.songTimedOut = true
                    self.log("单曲下载长时间无进展，已跳过并继续下一首。")
                    self.runner.terminateCurrentDownload()
                    return
                }
            }
        }
    }

    private func persistJob() {
        guard let job = downloadJob else { return }
        do { try DownloadJobStore(root: root).save(job) }
        catch { log("任务记录未保存：\(error.localizedDescription)") }
    }

    private func refreshReviewable() {
        guard let job = downloadJob else { reviewableSkips = []; return }
        reviewableSkips = job.entries.enumerated().compactMap { index, entry in
            guard entry.state == .skipped, let review = entry.review else { return nil }
            return ReviewableSkip(id: "\(job.id)#\(index)", jobID: job.id, entryIndex: index,
                                  title: entry.title, artist: entry.artist,
                                  candidateTitle: review.title, candidateArtist: review.artist,
                                  candidateAlbum: review.album, reason: review.reason, score: review.score)
        }
    }

    /// Download one song the matcher would not accept automatically, using
    /// the reviewed candidate the user picked from the review list. The
    /// entry flips back to pending with the candidate's URL and the usual
    /// per-song queue takes it from there; wrap-up renumbers it into the
    /// playlist folder and rebuilds the report with the new state.
    func downloadReview(_ skip: ReviewableSkip) {
        guard !busy, !importing, !loadingLocalState, !shutDown else { return }
        let loaded = (downloadJob?.id == skip.jobID) ? downloadJob : DownloadJobStore(root: root).load(id: skip.jobID)
        guard var job = loaded,
              job.entries.indices.contains(skip.entryIndex),
              let review = job.entries[skip.entryIndex].review else { return }
        job.entries[skip.entryIndex].url = review.url
        job.entries[skip.entryIndex].state = .pending
        job.entries[skip.entryIndex].review = nil
        job.entries[skip.entryIndex].detail = "人工复核确认下载"
        job.finishedAt = nil
        job.updatedAt = Date()
        downloadJob = job
        persistJob()
        refreshReviewable()
        if let selected = selectedPlaylist, selected.id == job.id { pendingPlaylist = selected }
        downloadIssue = nil
        busy = true; failed = false; percent = 0; completed = 0; queue = 1
        skipped = job.entries.filter { $0.state == .skipped }.count
        generation = UUID()
        let session = generation
        phase = "正在准备"; taskTitle = "正在下载复核歌曲"
        taskDetail = "\(skip.title)" + (skip.artist.isEmpty ? "" : " · \(skip.artist)")
        log("按复核确认下载：《\(review.title)》· \(review.artist)")
        workflow = Task { [self] in
            do {
                try applyDownloadSettings()
                let service = importer
                let directory = root
                let scan = Task.detached(priority: .utility) { service.snapshotAudioFiles(in: directory) }
                let files = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
                try Task.checkCancellation()
                guard session == generation else { return }
                snapshot = files
                startNextJobSong(session: session)
            } catch {
                guard !Task.isCancelled, session == generation else { return }
                fail("下载没有完成", error.localizedDescription)
            }
        }
    }

    /// NetEase-first runs: fetch every entry that carries a NetEase ID
    /// straight from NetEase before the Apple queue starts. Successes flip
    /// to downloaded with the source tagged, so the per-song queue skips
    /// them and wrap-up reconciliation treats the files like any other
    /// download. Failures keep their Apple route; the reason is remembered
    /// so wrap-up can annotate the ledger (e.g. 需要黑胶 VIP) instead of
    /// retrying a download that cannot succeed.
    private func prefetchNetease(session: UUID, selection: PlaylistSelection) async {
        guard var job = downloadJob,
              let folderName = DownloaderRunner.sanitizedBatchFolder(selection.name) else { return }
        let targets = job.entries.indices.filter { job.entries[$0].neteaseID != nil }
        guard !targets.isEmpty else { return }
        let folder = root.appendingPathComponent("AM-DL downloads").appendingPathComponent(folderName)
        let client = FallbackSourceClient(cookieHeader: neteaseCookieHeader)
        phase = "正在从网易云直下"
        var fetchedCount = 0
        for (offset, index) in targets.enumerated() {
            guard session == generation, !Task.isCancelled, !shutDown else { return }
            guard let neteaseID = job.entries[index].neteaseID else { continue }
            taskDetail = "网易云直下 · \(offset + 1) / \(targets.count)：\(job.entries[index].title)"
            do {
                let fetched = try await client.fetch(neteaseID: neteaseID, title: job.entries[index].title, artist: job.entries[index].artist, into: folder)
                job.entries[index].state = .downloaded
                job.entries[index].source = "netease"
                job.entries[index].detail = fetched.format == "flac" ? "网易云直下 · 无损 FLAC" : "网易云直下" + (fetched.bitrateKbps.map { " · 约 \($0) kbps" } ?? "")
                fetchedCount += 1
            } catch {
                neteasePrefetchNotes[neteaseID] = await client.unavailabilityNote(neteaseID: neteaseID)
            }
        }
        job.updatedAt = Date()
        downloadJob = job
        persistJob()
        skipped = job.entries.filter { $0.state == .skipped }.count
        refreshReviewable()
        log("网易云优先：直下成功 \(fetchedCount) / \(targets.count) 首，其余走 Apple 匹配补缺。")
    }

    /// Runs once when the per-song queue drains: save the selection, verify
    /// local matches, renumber, then close out the job ledger with its
    /// end-of-run report.
    private func wrapUpDownload() {
        guard busy else { return }
        progressMonitor?.cancel()
        songWatchdog?.cancel()
        let session = generation
        let service = importer
        let directory = root
        let previous = snapshot
        phase = "正在核对文件"
        workflow = Task {
            // Fallback pass: songs the Apple matcher skipped get one attempt
            // straight from NetEase by their exact track ID before the file
            // reconciliation below, so anything fetched lands in the same
            // batch folder and flows through numbering and health checks
            // like a normal download. The ledger tags the source.
            if fallbackEnabled, var job = downloadJob, let selection = pendingPlaylist,
               let folderName = DownloaderRunner.sanitizedBatchFolder(selection.name) {
                let skippedIndices = job.entries.indices.filter { job.entries[$0].state == .skipped && job.entries[$0].neteaseID != nil }
                if !skippedIndices.isEmpty {
                    phase = "正在尝试备用源"
                    let folder = directory.appendingPathComponent("AM-DL downloads").appendingPathComponent(folderName)
                    let client = FallbackSourceClient(cookieHeader: self.neteaseCookieHeader)
                    var fetchedCount = 0
                    var annotatedCount = 0
                    for index in skippedIndices {
                        guard !Task.isCancelled, session == generation, !shutDown else { return }
                        let entry = job.entries[index]
                        guard let neteaseID = entry.neteaseID else { continue }
                        // A NetEase-first run already learned why this track
                        // cannot be fetched; record that in the ledger
                        // instead of asking again.
                        if let note = neteasePrefetchNotes[neteaseID] {
                            job.entries[index].detail = note
                            annotatedCount += 1
                            continue
                        }
                        do {
                            let fetched = try await client.fetch(neteaseID: neteaseID, title: entry.title, artist: entry.artist, into: folder)
                            job.entries[index].state = .downloaded
                            job.entries[index].source = "netease"
                            job.entries[index].detail = fetched.format == "flac" ? "网易云直下 · 无损 FLAC" : "网易云直下" + (fetched.bitrateKbps.map { " · 约 \($0) kbps" } ?? "")
                            fetchedCount += 1
                            log("备用源补下：《\(entry.title)》· \(entry.artist)（网易云直下，来源已记录）")
                        } catch {
                            // The ledger, not just the log, must say why the
                            // song is missing — above all when the honest
                            // answer is "needs 黑胶 VIP".
                            if let fallbackError = error as? FallbackSourceClient.FallbackError {
                                switch fallbackError {
                                case .noStream:
                                    job.entries[index].detail = await client.unavailabilityNote(neteaseID: neteaseID)
                                case .emptyDownload:
                                    job.entries[index].detail = "网易云返回的文件不完整"
                                }
                            } else {
                                job.entries[index].detail = "网易云下载失败：\(error.localizedDescription)"
                            }
                            annotatedCount += 1
                            log("备用源未下到：《\(entry.title)》· \(entry.artist)：\(error.localizedDescription)")
                        }
                    }
                    if fetchedCount > 0 || annotatedCount > 0 {
                        job.updatedAt = Date()
                        downloadJob = job
                        persistJob()
                        refreshReviewable()
                    }
                    phase = "正在核对文件"
                }
            }
            let scan = Task.detached(priority: .utility) { service.changedAudioFiles(in: directory, comparedTo: previous) }
            let changed = await withTaskCancellationHandler(operation: { await scan.value }, onCancel: { scan.cancel() })
            guard !Task.isCancelled, session == generation, !shutDown else { return }
            snapshot.removeAll()
            do {
                if let playlist = pendingPlaylist {
                    try PlaylistLibrary(root: root).save(playlist)
                    selectedPlaylist = playlist
                } else {
                    try PlaylistLibrary(root: root).clearSelection()
                    selectedPlaylist = nil
                }
            } catch {
                fail("歌单记录未保存", "音频已保留，请重试以保存歌单归属后再导入。")
                return
            }
            var missing = 0
            var localCount: Int?
            if let selection = pendingPlaylist {
                do {
                    let checked = try await Task.detached(priority: .utility) {
                        try PlaylistLibrary(root: directory).nativeFiles(for: selection)
                    }.value
                    guard !Task.isCancelled, session == generation, !shutDown else { return }
                    missing = checked.missing
                    localCount = checked.files.count
                } catch {
                    fail("下载未确认完成", downloadIssue ?? "无法确认专辑或歌单中的本地歌曲；已有文件均保留。")
                    return
                }
            } else if changed.isEmpty {
                fail("下载未确认完成", downloadIssue ?? "未发现新增或更新的音频；可能已存在，也可能下载器未成功，请检查下载目录和服务。")
                return
            }
            if let downloadIssue {
                fail("下载未确认完成", downloadIssue)
                return
            }
            if let selection = pendingPlaylist {
                let renumbered = await Task.detached(priority: .utility) {
                    PlaylistLibrary(root: directory).renumberBatchFolder(for: selection)
                }.value
                guard !Task.isCancelled, session == generation, !shutDown else { return }
                if renumbered.renamed > 0 {
                    log("已按歌单顺序整理下载编号：\(renumbered.renamed) 首。")
                }
                let playlistCount = await Task.detached(priority: .utility) {
                    PlaylistLibrary(root: directory).writeM3U(for: selection)
                }.value
                guard !Task.isCancelled, session == generation, !shutDown else { return }
                if playlistCount > 0 {
                    log("已生成通用播放列表（.m3u8）：\(playlistCount) 首，其他播放器打开歌单文件夹即可使用。")
                }
            }
            phase = "正在核对文件"
            let rateCap = quality.maximumSampleRate
            let healthWarnings = await Task.detached(priority: .utility) { () -> [String] in
                var warnings: [String] = []
                let checker = IPodImporter()
                for item in changed {
                    let result = checker.healthCheck(item.url)
                    if !result.playable {
                        warnings.append("文件不可播：\(item.url.lastPathComponent)")
                    } else if let rate = result.sampleRate, rate > rateCap {
                        warnings.append("采样率 \(rate) Hz 超过当前音质上限：\(item.url.lastPathComponent)")
                    }
                }
                return warnings
            }.value
            guard !Task.isCancelled, session == generation, !shutDown else { return }
            for warning in healthWarnings { log("体检：\(warning)") }
            busy = false
            completed = changed.count; percent = 100
            phase = missing > 0 ? "下载结束 · 有未匹配歌曲" : "下载完成"
            taskTitle = "新增或更新 \(changed.count) 首" + (localCount.map { " · 本地匹配 \($0) 首" } ?? "")
            taskDetail = missing > 0 ? "仍有 \(missing) 首未匹配或未下载；不会生成完整歌单" : "本地检查完成；不会自动导入设备"
            log("下载器结束；新增或更新 \(changed.count) 个音频文件，\(missing) 首未匹配或未下载。")
            if var job = downloadJob {
                job.finishedAt = Date()
                job.updatedAt = Date()
                let names = { (state: DownloadJobEntryState) -> [String] in
                    job.entries.filter { $0.state == state }.map { $0.artist.isEmpty ? $0.title : "\($0.title) · \($0.artist)" }
                }
                let fallbackNames = job.entries.filter { $0.state == .downloaded && $0.source == "netease" }
                    .map { $0.artist.isEmpty ? $0.title : "\($0.title) · \($0.artist)" }
                let report = DownloadJobReport(generatedAt: Date(), downloaded: names(.downloaded),
                                               skipped: names(.skipped), failed: names(.failed), timedOut: names(.timedOut),
                                               warnings: healthWarnings, fallbackDownloads: fallbackNames)
                job.report = report
                downloadJob = job
                persistJob()
                refreshReviewable()
                let skippedLines = job.entries.filter { $0.state == .skipped }.map { entry -> String in
                    let base = entry.artist.isEmpty ? entry.title : "\(entry.title) · \(entry.artist)"
                    if let review = entry.review { return base + "（最接近候选：《\(review.title)》· \(review.artist)，\(review.reason)）" }
                    return base
                }
                if !skippedLines.isEmpty { log("跳过 \(skippedLines.count) 首：\(skippedLines.joined(separator: "；"))") }
                if !report.failed.isEmpty { log("失败 \(report.failed.count) 首：\(report.failed.joined(separator: "；"))") }
                if !report.timedOut.isEmpty { log("超时跳过 \(report.timedOut.count) 首：\(report.timedOut.joined(separator: "；"))") }
                if !report.fallbackDownloads.isEmpty { log("其中备用源（网易云）补下 \(report.fallbackDownloads.count) 首：\(report.fallbackDownloads.joined(separator: "；"))") }
            }
            refreshDevice()
        }
    }

    /// Export the current playlist's local files to a folder the user
    /// picks, with an .m3u8 beside them: the one general-purpose preset,
    /// original files copied as-is under the playlist's name.
    func exportCurrentPlaylist() {
        guard !busy, !importing, !loadingLocalState, !shutDown else { return }
        guard let selection = selectedPlaylist else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "把《\(selection.name)》的本地歌曲导出到所选文件夹"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let directory = root
        Task {
            let result = await Task.detached(priority: .utility) { () -> String in
                do {
                    let library = PlaylistLibrary(root: directory)
                    let found = try library.nativeFiles(for: selection)
                    let folderName = PlaylistLibrary.deviceFolderName(selection)
                    let folder = destination.appendingPathComponent(folderName)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var copied: [URL] = []
                    for item in found.files {
                        let target = folder.appendingPathComponent(item.url.lastPathComponent)
                        if !FileManager.default.fileExists(atPath: target.path) {
                            try FileManager.default.copyItem(at: item.url, to: target)
                        }
                        copied.append(target)
                    }
                    let ordered = PlaylistLibrary.orderedAudioFiles(copied)
                    let content = PlaylistLibrary.m3uContent(name: selection.name, files: ordered, tracks: selection.tracks)
                    try content.write(to: folder.appendingPathComponent(folderName + ".m3u8"), atomically: true, encoding: .utf8)
                    return "已导出 \(ordered.count) 首到 \(folder.path)，含 .m3u8 播放列表。"
                } catch {
                    return "导出失败：\(error.localizedDescription)"
                }
            }.value
            guard !shutDown else { return }
            log(result)
        }
    }

    /// Stage 5c: decode .ncm files the user already downloaded with
    /// the official NetEase client. Decoding is purely local; results
    /// land in the "NCM 导入" folder, and in Rockbox mode they go
    /// straight into the standard import preview from there.
    func importNCM() {
        guard !busy, !importing, !loadingLocalState, !shutDown else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "解码"
        panel.message = "选择官方客户端下载的 .ncm 文件或所在文件夹"
        guard panel.runModal() == .OK else { return }
        var sources: [URL] = []
        for url in panel.urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
                    for case let file as URL in walker where file.pathExtension.lowercased() == "ncm" {
                        sources.append(file)
                    }
                }
            } else if url.pathExtension.lowercased() == "ncm" {
                sources.append(url)
            }
        }
        guard !sources.isEmpty else {
            fail("没有找到 .ncm 文件", "所选位置里没有扩展名为 .ncm 的文件。")
            return
        }
        busy = true
        phase = "解码 .ncm"
        taskTitle = "正在解码 \(sources.count) 个 .ncm 文件"
        taskDetail = "本地解码，不联网、不需要账号"
        let directory = root
        let session = generation
        workflow = Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (folder: URL, ok: [String], failed: [String]) in
                let folder = directory.appendingPathComponent("NCM 导入")
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var ok: [String] = []
                var failed: [String] = []
                var usedNames = Set<String>()
                for source in sources {
                    do {
                        let song = try NcmDecoder.decode([UInt8](try Data(contentsOf: source)))
                        let stem = Self.ncmFileStem(song: song, fallback: source.deletingPathExtension().lastPathComponent)
                        var candidate = stem
                        var suffix = 2
                        while usedNames.contains(candidate.lowercased())
                                || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate + "." + song.format).path) {
                            candidate = "\(stem) (\(suffix))"
                            suffix += 1
                        }
                        usedNames.insert(candidate.lowercased())
                        let fileURL = folder.appendingPathComponent(candidate + "." + song.format)
                        try NcmTagWriter.tagged(song).write(to: fileURL)
                        if let cover = song.cover, !cover.isEmpty {
                            let coverURL = folder.appendingPathComponent(candidate + (song.coverMIME == "image/png" ? ".png" : ".jpg"))
                            try? cover.write(to: coverURL)
                        }
                        ok.append(candidate)
                    } catch {
                        failed.append("\(source.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                return (folder, ok, failed)
            }.value
            guard !shutDown, generation == session else { return }
            busy = false
            for line in outcome.failed { log("ncm 解码失败 · \(line)") }
            guard !outcome.ok.isEmpty else {
                fail("解码未成功", "没有文件被解开，具体原因已记入运行日志。")
                return
            }
            phase = "解码完成"
            taskTitle = "已解码 \(outcome.ok.count) 首到「NCM 导入」"
            taskDetail = outcome.failed.isEmpty ? "文件在项目目录的「NCM 导入」文件夹中" : "另有 \(outcome.failed.count) 首失败，见运行日志"
            log("ncm 解码完成：\(outcome.ok.count) 首 → \(outcome.folder.path)")
            if resolvedImportMode == .rockbox, device != nil {
                previewDecodedFolder(outcome.folder)
            }
        }
    }

    private nonisolated static func ncmFileStem(song: NcmDecoder.Song, fallback: String) -> String {
        let base: String
        if !song.title.isEmpty {
            base = song.artist.isEmpty ? song.title : "\(song.artist) - \(song.title)"
        } else {
            base = fallback
        }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = base.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    /// The Rockbox half of importMusic(), pointed at an arbitrary
    /// folder instead of the download root: validate, preview, and let
    /// the shared confirm step do the writing.
    private func previewDecodedFolder(_ folder: URL) {
        refreshDevice()
        guard let target = device, target.canImport else { return }
        importing = true; failed = false; percent = 0; queue = nil; completed = 0; skipped = 0
        phase = "1/4 · 扫描歌曲"; taskTitle = "正在统计解码歌曲"
        taskDetail = "先检查歌曲与目标，预览后再开始导入"
        let session = generation
        workflow = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let service = IPodImporter()
                    try service.validateFilesystem(on: target)
                    return try service.preview(service.audioFiles(in: folder), device: target,
                                               playlistName: "NCM 导入", playlistID: nil, missing: 0)
                }.value
                guard !shutDown, generation == session else { return }
                importing = false
                phase = "等待确认"; taskTitle = "Rockbox 导入预览已就绪"
                taskDetail = "确认后才写入设备"
                rockboxPreview = result
                NotificationCenter.default.post(name: .mbGoImport, object: nil)
            } catch {
                guard !shutDown, generation == session else { return }
                importing = false
                if IPodImporter.isDeviceIOError(error) { deviceIOFailure = true }
                fail("导入预览未完成", error.localizedDescription)
            }
        }
    }

    func importMusic() {
        guard !busy, !importing, !loadingLocalState, !shutDown else { return }
        refreshDevice()
        guard let target = device else { return }
        guard target.canImport else {
            fail("设备暂时无法导入", "请确认 iPod 已以可写方式挂载后重试。")
            return
        }
        if needsNativeInitialization {
            nativeInitializationAcknowledged = false
            selectedProfileID = target.identity.profile?.id ?? IPodKnowledge.defaultImportProfileID
            if !target.identity.allowsManualProfile(selectedProfileID), target.identity.profileID != selectedProfileID {
                selectedProfileID = IPodKnowledge.profiles.first(where: { target.identity.allowsManualProfile($0.id) })?.id ?? ""
            }
            nativePresentation = .initialize(NativeInitializationRequest(device: target))
            return
        }
        guard let mode = resolvedImportMode else {
            fail("导入方式不可用", "设备未检测到所选音乐库，请切换导入方式。")
            return
        }
        if PlaylistSource.identify(source) == .netease {
            let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let range = text.range(of: "[?&]id=([0-9]+)(?:[&#]|$)", options: .regularExpression)
            let currentID = range.map { String(text[$0]).dropFirst(4).prefix { $0.isNumber } }
            guard let playlist = selectedPlaylist, let currentID, String(currentID) == playlist.id,
                  let sourceLink = PlaylistSource.extractURL(text), sourceLink.host?.lowercased() == "music.163.com",
                  (sourceLink.path == playlist.sourceURL.path || (sourceLink.fragment ?? "").hasPrefix(playlist.sourceURL.path)) else {
                fail("歌单归属未确认", "请先下载当前链接对应的歌单，避免把旧歌单或其他专辑混入。")
                return
            }
        }
        if mode == .rockbox && PlaylistSource.identify(source) == .apple {
            fail("Apple Music 歌单顺序尚未确认", "当前版本无法可靠取得该链接的完整歌单顺序，因此不会把整个下载目录当作这份歌单导入。")
            return
        }
        if mode == .native { previewNativeImport(to: target); return }
        importing = true; failed = false; percent = 0; queue = nil; completed = 0; skipped = 0
        phase = "1/4 · 扫描歌曲"; taskTitle = "正在统计下载目录中的歌曲"
        taskDetail = "先检查歌曲与目标，预览后再开始导入"
        let session = generation
        let directory = root
        let playlist = selectedPlaylist
        let coverMaxPixel = ipodCover256 ? 256 : 600
        workflow = Task {
          do {
            do {
                try await Task.detached(priority: .utility) { try IPodImporter().validateFilesystem(on: target) }.value
            } catch {
                importing = false
                deviceIOFailure = true
                fail("iPod 目录无法读取", "已停止导入。请安全弹出后重新连接；若仍有输入/输出错误，请先检查设备文件系统。")
                return
            }
            if let playlist {
                phase = "1/4 · 准备歌单"; taskTitle = playlist.name
                taskDetail = "只处理这份歌单中的歌曲，并保留各自的原始封面"
            }
            let result = try await Task.detached(priority: .userInitiated) { [self] in
                let service = IPodImporter()
                var prepared: PreparedPlaylist?
                if let playlist {
                    prepared = try PlaylistLibrary(root: directory).prepare(playlist, coverData: Data(), coverMaxPixel: coverMaxPixel) { current, total, detail in
                        DispatchQueue.main.async { [self] in
                            guard self.importing, !self.shutDown, self.generation == session else { return }
                            self.phase = "1/4 · 准备歌单"
                            self.taskTitle = "\(playlist.name) · \(current) / \(total)"
                            self.taskDetail = detail + "；电脑原文件保持原专辑信息"
                            let fraction = Double(current) / Double(max(1, total))
                            self.percent = max(self.percent, detail.hasPrefix("核对") ? 10 * fraction : 10 + 15 * fraction)
                        }
                    }
                }
                return try service.preview(prepared?.files ?? service.audioFiles(in: directory), device: target,
                                           playlistName: playlist?.name, playlistID: playlist?.id, missing: prepared?.missing ?? 0)
            }.value
            guard !shutDown, generation == session else { return }
            importing = false
            phase = "等待确认"; taskTitle = "Rockbox 导入预览已就绪"
            taskDetail = "确认后才写入设备"
            rockboxPreview = result
          } catch {
            guard !shutDown, generation == session else { return }
            importing = false
            if IPodImporter.isDeviceIOError(error) { deviceIOFailure = true }
            fail("导入预览未完成", error.localizedDescription)
          }
        }
    }

    func cancelRockboxPreview() {
        rockboxPreview = nil
        phase = "已取消"; taskTitle = "导入已取消"; taskDetail = "设备内容未更改"
    }

    func confirmRockboxImport(_ preview: RockboxImportPreview) {
        guard rockboxPreview?.id == preview.id, !busy, !importing, !shutDown else { return }
        refreshDevice()
        guard device?.matchesImportTarget(preview.device) == true, resolvedImportMode == .rockbox else {
            rockboxPreview = nil; fail("设备已变化", "请重新选择设备并预览。")
            return
        }
        rockboxPreview = nil
        importing = true; failed = false
        let target = preview.device, session = generation
        workflow = Task {
          do {
            let report = try await Task.detached(priority: .userInitiated) { [self] in
                let service = IPodImporter()
                try service.validatePreview(preview)
                let signatures = Dictionary(preview.ready.compactMap { item in item.signature.map { (item.url, $0) } }, uniquingKeysWith: { first, _ in first })
                let playlistID = preview.missing == 0 && preview.ready.count == preview.items.count ? preview.playlistID : nil
                return service.importFiles(preview.ready.map { (url: $0.url, root: $0.root) }, to: target, expectedSignatures: signatures, playlistID: playlistID, playlistName: preview.playlistName) { progress in
                    DispatchQueue.main.async { [self] in
                        guard self.importing, !self.shutDown, self.generation == session else { return }
                        self.queue = progress.total
                        self.completed = progress.imported
                        self.skipped = progress.existing
                        self.percent = progress.fraction * 100
                        switch progress.stage {
                        case .copying:
                            self.phase = "2/4 · 检查并复制"
                            self.taskTitle = "已处理 \(progress.processed) / \(progress.total) 首 · 剩余 \(max(0, progress.total - progress.processed)) 首"
                            self.taskDetail = "\(progress.filename) · 新增 \(progress.imported) 首，已有 \(progress.existing) 首；请保持连接"
                        case .covers:
                            self.phase = "2/4 · 整理封面"
                            self.taskTitle = "歌曲处理完毕，正在整理专辑封面"
                            self.taskDetail = "接下来校验设备文件；请保持 iPod 连接"
                        case .verifying:
                            self.phase = "3/4 · 校验设备文件"
                            self.taskTitle = "正在确认设备中的歌曲可读取"
                            self.taskDetail = "\(progress.filename) · 读取检查不能代替设备播放验证"
                        case .library:
                            self.phase = "4/4 · 整理导入结果"
                            self.taskTitle = "正在准备设备端更新提示"
                            self.taskDetail = "保留现有 Rockbox 设置"
                        }
                    }
                }
            }.value
            guard !shutDown, generation == session else { return }
            let missing = preview.missing
            let excluded = preview.items.count - preview.ready.count
            if report.interrupted {
                importing = false
                completed = report.imported; queue = report.sourceFiles
                fail("导入已中断", "已新增 \(report.imported) 首，未处理 \(max(0, report.sourceFiles - report.processedFiles)) 首。请查看记录并重新预览；原文件和旧副本均保留。")
                for message in report.messages { log(message) }
                return
            }
            importing = false; phase = "导入完成"; percent = 100
            queue = report.sourceFiles; completed = report.imported
            skipped = report.alreadyPresent + report.skippedUnplayable + missing + excluded
            taskTitle = "已导入 \(report.imported) 首歌曲"
            taskDetail = "预览中未导入 \(excluded) 首 · 跳过 \(report.skippedUnplayable) 首 · 失败 \(report.failedFiles) 首"
            if let instruction = report.libraryInstruction {
                taskDetail = instruction
                log(instruction)
            }
            log("导入结束：\(report.imported) 首新增，\(report.alreadyPresent) 首已存在，\(report.skippedUnplayable) 首跳过，\(report.failedFiles) 首失败。")
            if excluded > 0 {
                phase = "导入结束 · 有未处理歌曲"
                log("预览中有 \(excluded) 首未复制；同名文件、无法确认的音频和冲突均已保留。")
            }
            if preview.playlistID != nil && (excluded > 0 || missing > 0) { log("存在未匹配或未复制的歌曲，本次未生成完整 M3U8 歌单。") }
            if missing > 0 {
                log("\(missing) 首未找到唯一且版本一致的本地文件，未混入其他歌曲。")
                phase = "导入完成 · 有跳过"
                taskTitle = "已复制 \(report.imported) 首 · \(missing) 首未匹配"
            }
            if report.warningCount > 0 {
                phase = "导入结束 · 有提示"
                taskDetail = "\(report.warningCount) 项需要检查；已有设备文件不会被覆盖"
                log("有 \(report.warningCount) 项导入或音频检查提示；同名但内容不同的文件会保留。")
                for message in report.messages { log(message) }
            }
          } catch {
            guard !shutDown, generation == session else { return }
            importing = false
            if IPodImporter.isDeviceIOError(error) { deviceIOFailure = true }
            fail("Rockbox 导入未完成", error.localizedDescription)
          }
        }
    }

    private func previewNativeImport(to target: IPodDevice) {
        importing = true; failed = false; percent = 0; queue = nil; completed = 0; skipped = 0
        phase = "准备原生导入"; taskTitle = "正在核对歌曲与原生音乐库"
        taskDetail = "预览完成后再由你确认写入"
        let directory = root, playlist = selectedPlaylist, session = generation
        workflow = Task {
            do {
                let plan = try await Task.detached(priority: .userInitiated) { [self] in
                    let selected = try PlaylistLibrary(root: directory).nativeFiles(for: playlist)
                    var plan = try NativeIPodImporter(root: directory).prepare(files: selected.files, device: target, missing: selected.missing, playlist: playlist) { detail in
                        DispatchQueue.main.async { [self] in
                            guard self.generation == session, self.importing, !self.shutDown else { return }
                            self.taskDetail = detail
                        }
                    }
                    plan.unmatchedSongs = selected.unmatched
                    return plan
                }.value
                guard !shutDown, generation == session else { return }
                importing = false
                refreshDevice()
                guard device?.matchesImportTarget(target) == true else { throw NativeImportError.libraryChanged }
                nativeTask = NativeImportTask(plan: plan)
                queue = nativeTask?.total; phase = "等待确认原生导入"
                taskTitle = "预计新增 \(plan.summary.additions) 首 · 已有 \(plan.summary.existing) 首"
                taskDetail = "预览已完成，尚未写入设备"
                if plan.sourceCount == 0 {
                    phase = "没有首轮兼容歌曲，等待选择"
                    nativeReview = NativeConversionReview(plan: plan, imported: 0, existing: 0)
                } else { nativePlan = plan }
            } catch {
                guard !shutDown, generation == session else { return }
                importing = false; fail("原生导入预览未完成", error.localizedDescription)
            }
        }
    }

    func cancelNativeImport() {
        nativePlan = nil
        nativeTask?.stage = "已取消；没有写入设备"
        phase = "已取消原生导入"; taskTitle = "没有写入设备"; taskDetail = "可重新选择导入方式"
    }

    func confirmNativeImport(_ plan: NativeImportPlan) {
        guard nativePlan?.id == plan.id, !busy, !importing, !shutDown else { return }
        refreshDevice()
        guard device?.matchesImportTarget(plan.device) == true else { cancelNativeImport(); return }
        nativePlan = nil; importing = true; failed = false; percent = 0
        nativeTask?.stage = "首轮导入中"
        nativeTask?.writeVerified = false
        phase = "原生导入"; taskTitle = "正在备份并导入原生音乐库"
        let directory = root, session = generation
        workflow = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { [self] in
                    try NativeIPodImporter(root: directory).execute(plan) { detail in
                        DispatchQueue.main.async { [self] in
                            guard self.generation == session, self.importing, !self.shutDown else { return }
                            self.updateNativeProgress(detail)
                        }
                    }
                }.value
                guard !shutDown, generation == session else { return }
                importing = false; percent = 100; completed = result.completed
                nativeTask?.imported = result.completed; nativeTask?.existing = result.existing
                nativeTask?.playlistCount = result.playlistCount; nativeTask?.writeVerified = true
                if let backup = result.backup { nativeTask?.backups.append(backup) }
                nativeTask?.stage = "首轮设备文件与数据库已核对；实机播放待确认"
                if let assessment = plan.assessment {
                    let ready = Set(assessment.ready.map(\.id))
                    if var task = nativeTask {
                        for index in task.entries.indices where ready.contains(task.entries[index].id) { task.entries[index].status = "首轮设备核对完成" }
                        nativeTask = task
                    }
                }
                skipped = result.existing + plan.missing
                phase = "原生导入完成"
                taskTitle = "新增 \(result.completed) 首 · 已有 \(result.existing) 首"
                taskDetail = "请安全弹出，在 iPod 原生音乐菜单检查播放。"
                if plan.missing > 0 { taskDetail += "\(plan.missing) 首未匹配，未导入。" }
                if let backup = result.backup { log("原生同步引擎报告完成；数据库备份：\(backup.path)") }
                else { log("歌曲均已存在，本次没有写入原生音乐库。") }
                if let assessment = plan.assessment, !assessment.pending.isEmpty || !assessment.blocked.isEmpty {
                    phase = "兼容歌曲已处理，等待选择"
                    percent = 0
                    taskDetail = "待转换 \(assessment.pending.count) 首 · 无法确认 \(assessment.blocked.count) 首"
                    nativeReview = NativeConversionReview(plan: plan, imported: result.completed, existing: result.existing)
                    nativeTask?.stage = "首轮已完成，等待选择剩余歌曲"
                }
            } catch {
                guard !shutDown, generation == session else { return }
                importing = false; fail("原生导入未完成", error.localizedDescription)
                nativeTask?.stage = "首轮未确认完成：" + error.localizedDescription
                nativeTask?.writeVerified = false
                if FileManager.default.fileExists(atPath: plan.backupURL.path) { nativeTask?.backups.append(plan.backupURL) }
                log("原生导入未确认成功；备份位置（若已生成）：\(plan.backupURL.path)")
            }
        }
    }

    func skipNativeConversions(_ review: NativeConversionReview) {
        guard nativeReview?.id == review.id else { return }
        nativeReview = nil
        phase = "本轮导入结束 · 有跳过"; percent = 100
        completed = review.imported
        skipped = review.existing + review.pending.count + review.blocked.count + review.plan.missing
        queue = (review.plan.assessment?.items.count ?? review.plan.sourceCount) + review.plan.missing
        taskTitle = "已新增 \(review.imported) 首 · 已有 \(review.existing) 首"
        taskDetail = "未转换 \(review.pending.count) 首 · 未确认 \(review.blocked.count) 首 · 未匹配 \(review.plan.missing) 首"
        nativeTask?.stage = "本轮结束；\(review.pending.count) 首由用户选择不转换，实机播放待确认"
    }

    func convertNativeSelections(_ review: NativeConversionReview, selectedIDs: Set<String>) {
        guard nativeReview?.id == review.id, !busy, !importing, !shutDown else { return }
        let selected = review.pending.filter { selectedIDs.contains($0.id) && $0.target != nil }
        guard !selected.isEmpty else { return }
        refreshDevice()
        guard device?.matchesImportTarget(review.plan.device) == true else { nativeReview = nil; fail("设备已变化", "请重新连接并预览。"); return }
        nativeReview = nil; importing = true; failed = false; percent = 0
        nativeTask?.writeVerified = false
        nativeTask?.stage = "正在生成所选兼容副本；保留首轮已确认结果"
        phase = "转换所选歌曲"; taskTitle = "保留原文件，生成兼容 ALAC 副本"
        let directory = root, session = generation
        workflow = Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) { [self] in
                    let base = directory.appendingPathComponent("work/native-conversions/\(UUID().uuidString)")
                    var ready: [(url: URL, root: URL)] = [], notices: [String] = []
                    var failures = 0
                    var entries: [NativeTaskEntry] = []
                    for (index, item) in selected.enumerated() {
                        let destination = base.appendingPathComponent(String(index))
                            .appendingPathComponent(item.url.deletingPathExtension().lastPathComponent + ".m4a")
                        do {
                            let gain = try NativeAudioTools.convert(item, to: destination, target: item.target!)
                            ready.append((destination, base))
                            notices.append("已生成兼容副本：\(item.url.lastPathComponent) → \(item.target!.description)"
                                + (item.spec?.rate != item.target?.rate ? "；" + NativeAudioTools.resamplerName : "")
                                + (gain > 0 ? "；为避免削波降低 \(String(format: "%.2f", gain)) dB" : ""))
                            entries.append(NativeTaskEntry(original: item.url, sourceSpec: item.spec?.description ?? "未知",
                                targetSpec: item.target!.description, status: "兼容副本设备核对完成",
                                detail: "降低规格的 ALAC 副本；保留最高规格原文件。"
                                    + (item.spec?.rate != item.target?.rate ? NativeAudioTools.resamplerName + "；" : "采样率保持；")
                                    + "最终 16-bit 量化使用 TPDF 抖动。"
                                    + (gain > 0 ? "防削波衰减 \(String(format: "%.2f", gain)) dB。" : ""), converted: destination))
                        } catch {
                            failures += 1
                            notices.append("转换未完成：\(item.url.lastPathComponent)；\(error.localizedDescription)")
                            entries.append(NativeTaskEntry(original: item.url, sourceSpec: item.spec?.description ?? "未知",
                                targetSpec: item.target?.description ?? "未知", status: "转换失败", detail: error.localizedDescription))
                        }
                        DispatchQueue.main.async { [self] in
                            guard self.generation == session, self.importing, !self.shutDown else { return }
                            self.taskDetail = "转换检查 \(index + 1) / \(selected.count) 首"
                            self.nativeTask?.stage = self.taskDetail
                            self.percent = Double(index + 1) / Double(selected.count) * 65
                        }
                    }
                    guard !ready.isEmpty else { return (Optional<NativeImportResult>.none, notices, failures, entries) }
                    let service = NativeIPodImporter(root: directory)
                    let convertedPlan = try service.prepare(files: ready, device: review.plan.device, missing: 0, playlist: review.plan.playlist) { _ in }
                    guard convertedPlan.sourceCount == ready.count else { throw NativeImportError.invalidPlan }
                    let result = try service.execute(convertedPlan) { detail in
                        DispatchQueue.main.async { [self] in
                            guard self.generation == session, self.importing, !self.shutDown else { return }
                            self.updateNativeProgress(detail)
                        }
                    }
                    return (Optional(result), notices, failures, entries)
                }.value
                guard !shutDown, generation == session else { return }
                let (result, notices, failures, entries) = outcome
                importing = false; percent = 100
                completed = review.imported + (result?.completed ?? 0)
                let existing = review.existing + (result?.existing ?? 0)
                let unselected = review.pending.count - selected.count
                nativeTask?.imported = completed; nativeTask?.existing = existing
                nativeTask?.pending = unselected; nativeTask?.conversionFailures = failures
                nativeTask?.playlistCount = result?.playlistCount ?? nativeTask?.playlistCount
                nativeTask?.writeVerified = result != nil || review.imported > 0 || review.existing > 0
                for entry in entries {
                    if let index = nativeTask?.entries.firstIndex(where: { $0.id == entry.id }) { nativeTask?.entries[index] = entry }
                }
                if let backup = result?.backup { nativeTask?.backups.append(backup) }
                nativeTask?.stage = failures == 0 ? "两阶段设备写入核对完成；实机播放待确认" : "兼容歌曲已保留；有转换失败，实机播放待确认"
                skipped = existing + unselected + review.blocked.count + review.plan.missing + failures
                queue = (review.plan.assessment?.items.count ?? review.plan.sourceCount) + review.plan.missing
                phase = failures == 0 ? "本轮原生导入结束" : "本轮导入结束 · 有失败"
                failed = failures > 0
                taskTitle = "已新增 \(completed) 首 · 已有 \(existing) 首"
                taskDetail = "转换失败 \(failures) 首 · 未转换 \(unselected) 首 · 未确认 \(review.blocked.count) 首 · 未匹配 \(review.plan.missing) 首"
                for notice in notices { log(notice) }
                if let backup = result?.backup { log("转换阶段数据库备份：" + backup.path) }
            } catch {
                guard !shutDown, generation == session else { return }
                importing = false; completed = review.imported
                nativeTask?.writeVerified = false
                nativeTask?.stage = "转换阶段未确认完成；首轮已导入歌曲保留。" + error.localizedDescription
                fail("转换阶段未确认完成", "首轮新增 \(review.imported) 首已保留；\(error.localizedDescription)")
            }
        }
    }

    func rebuildMediaLibrary() {
        refreshDevice()
        guard canImport, let target = device, target.isRockbox else { return }
        importing = true; failed = false; percent = 0
        phase = "备份媒体库"; taskTitle = "正在备份并重置旧专辑索引"
        taskDetail = "音乐文件保留；完成后需要在 iPod「数据库」初始化"
        let session = generation
        let backup = root.appendingPathComponent("work/device-database-backups/\(UUID().uuidString)")
        workflow = Task {
            do {
                let count = try await Task.detached(priority: .utility) {
                    try IPodImporter().resetDatabase(on: target, backupDirectory: backup)
                }.value
                guard !shutDown, generation == session else { return }
                importing = false; percent = 100; phase = "等待 iPod 初始化"
                taskTitle = "旧索引已备份，等待设备建立新媒体库"
                taskDetail = "安全弹出并重启，在 iPod「数据库」初始化；完成后再打开 Cover Flow"
                log("已备份 \(count) 个数据库索引；音乐文件保留。")
                log(taskDetail)
            } catch {
                guard !shutDown, generation == session else { return }
                importing = false
                if IPodImporter.isDeviceIOError(error) { deviceIOFailure = true }
                fail("媒体库重置未完成", error.localizedDescription)
            }
        }
    }

    func fail(_ title: String, _ detail: String) {
        progressMonitor?.cancel()
        busy = false; failed = true; phase = "需要检查"; taskTitle = title; taskDetail = detail
        log(title)
    }

    func log(_ message: String) {
        logs.append(message)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

    func shutdown() {
        shutDown = true
        generation = UUID()
        deviceTimer?.invalidate()
        deviceTimer = nil
        deviceScanToken = UUID(); deviceScan?.cancel()
        localStateRestore?.cancel()
        localStateRestoreToken = UUID()
        workflow?.cancel(); runner.stop(); appleLoginPoll?.cancel()
        progressMonitor?.cancel()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observations.removeAll()
        nativeTaskWriter.flush()
        projectAccessURL?.stopAccessingSecurityScopedResource()
    }
}
