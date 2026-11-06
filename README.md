<p align="center">
  <img src="MacApp/Resources/MusicBridgeIcon.png" width="128" alt="Music Bridge — 银色 IPC3 图标">
</p>

# Music Bridge

<p align="center"><strong>简体中文</strong> · <a href="README.en.md">English</a></p>

给 iPod / Rockbox 爱好者的原生 macOS 音乐整理与导入工具。

用法很直接：粘贴歌单链接，连上你自己的本地下载工具，再手动把音乐导入 iPod。界面用 SwiftUI、系统字体和原生控件加 SF Symbols 写的，图标是一台银色的 IPC3。

**当前为源码测试版。** 已在 Apple Silicon、macOS 27.2 上验证过构建、启动、图标和未连接设备时的界面。完整的下载链路依赖外部服务和你自己的本地环境，还没有作为公开版本做过端到端验证。先拿少量文件、拿备份过的设备试。

## 先说清楚：它解决的是什么问题

现在往 iPod 里装歌，麻烦是散的：

- 原厂路线要靠 iTunes 或访达同步，格式还挑；装了 Rockbox 之后格式不挑了，但找歌、下载、导入还是各干各的；
- 歌单多半在网易云里，真无损音源在 Apple Music，两边对不上，一首一首手动找很费人；
- 能下 Apple Music 无损的工具基本是命令行，还得自己配一个带登录的解密服务；
- 下完往 iPod 里拷是另一件事，还得留心封面在不在、文件能不能播。

Music Bridge 就是把这条链子接起来的调度台：歌单链接进来，它负责匹配、下发下载，最后把文件送进 iPod。它本身不存歌、不带下载器、也不碰你的账号。账号只登在你本机的 wrapper 服务里，它只跟这个本地服务说话。更像一座桥，名字就是这么来的。

有四个地方是特意这样设计的：

- **账号不经手。** 登录在 wrapper-lite 里完成，应用只连本机地址 `127.0.0.1:12340` 问状态、发任务，你的密码它见不到。
- **导入必须手点。** 下载完、设备连上，都不会自动往 iPod 里写文件。点“开始导入”才复制，中间留了检查下载目录的机会。
- **导入带体检。** 复制前后用 ffprobe 逐首查：能不能解析、编码和码率对不对、封面在不在。完事出一份报告，导了几首、跳过几首、几首有问题，都写清楚。
- **下载和导入都平铺。** 下载完，整张歌单平铺放在一个以歌单命名的文件夹里，不再按歌手/专辑分层；导入 iPod 时，在 Music 下生成同名歌单文件夹，歌曲按歌单顺序编号，每首歌旁边放一张同名 .jpg 封面。

## 新手上路：从零跑通一遍

第一次跑通，要准备四样东西：一台 Mac（目前在 Apple Silicon 上验证过）；一个能用的 Apple Music 订阅；amdl 和 wrapper-lite 两个下载工具（见下面“配置本地下载工具”一节）；一台装了 Rockbox 的 iPod，而且已经备份过。

1. **先把应用跑起来。** 照“构建与启动”一节编译、打开，界面出来了，第一步就算过。
2. **把 wrapper-lite 启动并登录。** 在 wrapper-lite 的目录里，按它自己的说明跑登录脚本，用你的 Apple ID 登好。登录态只存在你本机。
3. **填连接设置。** 打开“连接设置…”（`⌘,`），填 amdl 的路径、下载工作目录（里面要放 `config.yaml`）和 wrapper 地址（默认 `http://127.0.0.1:12340`）。
4. **把下载品质先定好，这步别跳。** 打开工作目录里的 `config.yaml`，把 `alac-max` 改成 `48000`。这一项管下载的无损最高采样率，改完下来的文件最高就是 48 kHz。配我另一个仓库的 [Rockbox 完全体固件](https://github.com/ZexinLiu725/rockbox-ipod-classic-ultimate) 正合适，那台机器吃 48 以内的文件最舒服；高采样率的在它上面反而会卡。要是只在电脑上听，这步可以不管。
5. **拿一张小歌单练手。** 找一张歌不多的网易云或 Apple Music 歌单，把链接粘进主界面，开始下载，盯着日志看。匹配是按歌曲信息去 Apple Music 中国区目录里找的，版本对不上的会跳过，日志里会写明。
6. **导入 iPod。** 插上 iPod，等设备卡显示连接就绪。先扫一眼下载目录，确认都是你要的歌，再点“开始导入”。导完看报告：导入几首、已存在跳过几首、有没有无法播放的。
7. **弹出试听。** 挑几首从头放一遍，没问题，这条链就算跑通了。以后日常就是粘链接、下载、导入，三步循环。

出问题先查这两处：下载不动，多半是 wrapper 没启动或者登录掉了，先确认 `http://127.0.0.1:12340` 有没有响应；“开始导入”点不了，是设备没被认出来，检查 iPod 里有没有 `.rockbox` 或 `iPod_Control`，再看 `Music` 目录可不可写。

## 懒得自己配？让 Codex 帮你

上面七步自己走没问题，就是有点繁。也可以把下面这段话复制给 Codex（或者任何一个会写代码、能在你电脑上干活的 AI），让它一步一步带着你配。账号登录那一步它不能替你做，到时候它会停下来让你自己登，这是故意的。

> 帮我在这台 Mac 上把 Music Bridge 跑起来。仓库是 https://github.com/ZexinLiu725/music-bridge ，先把它的 README 从头读完，再按下面的顺序做，每一步做完向我报告结果，不要跳步：
>
> 1. 检查环境：macOS 版本、芯片型号、Swift 版本、Xcode 命令行工具是否齐全，再确认 ImageMagick 和 ffmpeg（ffprobe）装没装。缺什么先告诉我，装任何东西之前要我点头。
> 2. 把仓库 clone 到本地，按 README 的“构建与启动”编译并运行 --verify，把应用打开给我看。构建有警告先记下来，不要顺手改代码。
> 3. 帮我准备下载工具：amdl（https://github.com/zhaarey/apple-music-downloader ）和 wrapper-lite（https://github.com/WorldObservationLog/wrapper/tree/lite ）按它们各自仓库的说明安装。wrapper 需要登录 Apple ID，这一步停下来，让我自己在终端里跑登录脚本，你不要问我的账号、密码或验证码，也不要代我输入。
> 4. 等我登录完，你检查 wrapper 服务在 http://127.0.0.1:12340 是否正常响应，然后带我打开 Music Bridge 的“连接设置…”，把 amdl 路径、下载工作目录和 wrapper 地址填好。
> 5. 打开工作目录里的 config.yaml，把 alac-max 改成 48000 再保存，改之前先把原文件备份一份。这个设置是把下载的无损采样率封顶在 48 kHz，因为我要把歌导入装了 Rockbox 完全体固件的 iPod，那台机器吃 48 以内的文件最稳。
> 6. 先拿一张歌少的歌单小批量试：我把链接给你，你走下载，盯着日志，告诉我匹配成功几首、跳过几首、跳过的原因是什么。
> 7. 导入 iPod 之前必须先问我，得到我明确同意才点“开始导入”。导入完把报告念给我听：导入几首、已存在几首、无法播放几首。任何要覆盖、删除设备上已有文件的动作，都先停下来问我。

英文版（For English speakers）:

> Help me set up Music Bridge on this Mac. The repo is https://github.com/ZexinLiu725/music-bridge — read its README first, then follow these steps in order and report back after each one. Do not skip steps.
>
> 1. Check the environment: macOS version, chip, Swift version, Xcode Command Line Tools, and whether ImageMagick and ffmpeg (ffprobe) are installed. Tell me what is missing and ask before installing anything.
> 2. Clone the repo, build it as described in the README, run the verify script, and open the app so I can see it. Note any build warnings; do not change code to silence them.
> 3. Prepare the download tools: install amdl (https://github.com/zhaarey/apple-music-downloader) and wrapper-lite (https://github.com/WorldObservationLog/wrapper/tree/lite) following their own repos. The wrapper requires an Apple ID sign-in: stop there and let me run the login script myself in Terminal. Never ask for my account, password, or verification codes, and never type them for me.
> 4. After I confirm I am signed in, check that the wrapper service answers at http://127.0.0.1:12340, then walk me through Music Bridge's Connection Settings and fill in the amdl path, the download working directory, and the wrapper address.
> 5. In the working directory's config.yaml, back the file up first, then set alac-max to 48000 and save. This caps lossless downloads at 48 kHz, because I import into an iPod running the Rockbox Ultimate firmware, which plays files up to 48 kHz most reliably.
> 6. Test with a small playlist first: I will give you the link; run the download, watch the log, and tell me how many songs matched, how many were skipped, and why.
> 7. Always ask me before importing to the iPod, and only click "Start Import" after I explicitly agree. Afterwards, read me the report: how many imported, how many already existed, how many are unplayable. Stop and ask before anything overwrites or deletes files on the device.

## 可以做什么

- 识别网易云歌单或 Apple Music 公开歌单链接。
- 把网易云的歌曲信息匹配到 Apple Music；版本无法确认的会跳过。
- 通过你自己装的 `amdl` 和 wrapper-lite 发起下载，界面上能看到状态、进度和日志。
- iPod 的连接状态一直显示在界面上；只有连上可写设备，导入才会启用。
- 手动扫描下载目录，把文件复制到设备的 `Music` 目录，目录结构和旁置的 `cover.jpg` 都会保留。
- 用 `ffprobe` 检查文件能不能解析，以及编码、码率和内嵌封面。

下载完成、设备连上，都不会自动开始导入。只有点了“开始导入”，文件才会复制过去。

## 构建与启动

构建需要 macOS、Swift 6 或更新版本，以及带 macOS 27 SDK 的开发工具。源码最低能跑 macOS 14，旧系统上用的是兼容界面；目前实际验证过的环境是 macOS 27.2。

装好 Apple 开发工具和 ImageMagick，在仓库根目录执行：

```bash
brew install imagemagick
swift build --package-path MacApp
bash script/build_and_run.sh --verify
```

脚本会生成并打开 `dist/MusicBridgeApp.app`，正式图标也会一并打包。也可以只编译 Swift 包，或者用 `bash script/build_and_run.sh --logs` 看系统日志。

这一版没有做 Developer ID 签名和公证，也没有可以直接安装的发行包。

## 配置本地下载工具

这个仓库只有 macOS 应用本身，不带下载器，也不带登录环境。下载工具要另外装，照这两个项目的说明配置：

- [amdl](https://github.com/zhaarey/apple-music-downloader)
- [wrapper-lite](https://github.com/WorldObservationLog/wrapper/tree/lite)

在 Music Bridge 菜单里打开“连接设置…”（`⌘,`），填写：

1. `amdl` 可执行文件的绝对路径。
2. 下载器的工作目录，里面要有你自己的 `config.yaml`。
3. wrapper-lite 的服务地址，默认 `http://127.0.0.1:12340`。
4. wrapper 启动脚本，可选；服务已经在运行时可以不填。

这些路径存在本机的偏好设置里。账号登录和凭据在外部工具里配，不要把这类数据提交进仓库。

## iPod 导入

先备份设备，再把 Rockbox iPod 挂载好，保证可写。设备里要有 `Music` 目录，并且存在 `.rockbox`，或者同时存在 `iPod_Control`。

导入会扫描你在设置里填的音频目录，以及工作目录里名字以 `AM-DL` 开头的文件夹。点“开始导入”之前，先确认这些目录里装的都是你想复制过去的内容。

**同路径、同大小的文件会跳过；同名但大小不同的目标文件会被替换。** 去重只看路径和大小，两个大小一样的文件，内容不保证相同。导入中途不能取消，也没有回滚设备文件的功能。

媒体检查要用 `ffprobe`，应用运行时得能找到它。用 `brew install ffmpeg` 就能装上；如果从访达启动时找不到，检查一下应用继承到的 `PATH`。

还有一点：旁置的 `cover.jpg` 和音频里的内嵌封面是两项不同的检查，报告里内嵌封面的结果不代表 Rockbox 里的封面浏览效果。

## 已知限制与隐私

- 网易云链接会发给第三方的 GoMusic 服务；Apple Music 匹配会访问 Apple 的网页和目录接口。这些服务一变，相关功能可能跟着失效。
- 匹配用的是 Apple Music 中国区目录，跨区或者不同发行版本，不保证完全一致。
- wrapper-lite 要在本机登录有效，并且能正确返回 `/status`；这个应用不提供账号，也不提供订阅。
- 图标是静态 `.icns`，没有接入 Icon Composer 的系统动态折射。
- 只处理你有权访问的音乐。这个仓库不包含音乐、下载器、登录数据，也不包含任何第三方服务的访问授权。

## 修改图标

`MusicBridgeArtwork.png` 是 IPC3 的机身画稿，`MusicBridgeIcon.svg` 管圆角、留白和布局，`MusicBridgeIcon.png` 是构建时用的正式导出图。

改完画稿或布局，在装了 Node.js 和 `sharp` 的环境里跑 `node script/render_icon.cjs` 重新导出。平时构建直接用导出的 PNG，不需要 Node.js。各尺寸的 `.iconset` 只在临时目录里生成，打包完自动清掉。

## 反馈与许可

欢迎提 Issue 或 Pull Request。报问题时写清 macOS 版本、设备型号、触发步骤，再附上脱敏过的错误信息；账号凭据、完整配置、私人音乐和没脱敏的日志不要发上来。

本仓库采用 [MIT 许可证](LICENSE)。外部工具、服务、商标与素材来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
