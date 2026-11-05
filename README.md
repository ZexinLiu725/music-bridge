<p align="center">
  <img src="MacApp/Resources/MusicBridgeIcon.png" width="128" alt="Music Bridge — 银色 IPC3 图标">
</p>

# Music Bridge

给 iPod / Rockbox 爱好者的原生 macOS 音乐整理与导入工具。

用法很直接：粘贴歌单链接，连上你自己的本地下载工具，再手动把音乐导入 iPod。界面用 AppKit、系统字体和原生控件加 SF Symbols 写的，图标是一台银色的 IPC3。

**当前为源码测试版。** 已在 Apple Silicon、macOS 27.2 上验证过构建、启动、图标和未连接设备时的界面。完整的下载链路依赖外部服务和你自己的本地环境，还没有作为公开版本做过端到端验证。先拿少量文件、拿备份过的设备试。

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
