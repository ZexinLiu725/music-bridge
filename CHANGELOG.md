# 更新日志 / Changelog

## [现行源码] — 2026-11-05

版本 / Version: SwiftUI v4.3（bundle id `cn.unmeta.musicbridge.rebuilt`），提交 / commit `c199aa4`

### 变更 / Changed
- 下载默认音质改为 Apple Lossless 无损档并封顶 48 kHz（`alac-max` = 48000），不再默认下 Hi-Res 高采样率——配合 iPod Classic 的 48 kHz 输出上限，免得下回来还要再转码一遍
  Default download quality is now Apple Lossless capped at 48 kHz, matching the iPod Classic's 48 kHz output ceiling — no more hi-res downloads that need transcoding afterwards
- 下载改为整单平铺：一张歌单的歌直接平铺进以歌单命名的单个文件夹，不再按歌手、专辑拆子文件夹（amdl 新增 `--save-subfolder`）
  Downloads are now flat: a whole playlist lands in a single folder named after the playlist, with no per-artist or per-album subfolders
- 导入改为单层结构：导入 iPod 时只建一层以歌单命名的文件夹，歌曲按歌单顺序编号平铺，同名 jpg 封面一并导入
  Imports are now single-level: one folder named after the playlist, tracks flat inside numbered in playlist order, same-name jpg covers included

### 修复 / Fixed
- 修复导入时把歌曲套进多层嵌套副本目录的问题（歌单名/歌单 ID/UUID/逐首编号文件夹），现为单层歌单文件夹
  Fixed imports nesting tracks inside multi-level generated folders; they now land in a single playlist folder

### 说明 / Notes
- 音源机制：以网易云歌单信息为索引，实际音源是 Apple Music，下载后解密
  How it works: NetEase playlists serve as the index; the actual audio is downloaded from Apple Music and decrypted
- 文档补齐：界面口径统一为 SwiftUI，补平铺下载与单层导入的行为说明，与 Rockbox 固件仓库互链（提交 `423ea4b`）

## [文档] — 2026-11-06

- 新增英文版 README.en.md，README 顶部加中英切换链接（提交 `deca6bd`、`15ba889`）
  Added README.en.md with a language switcher at the top of both READMEs

## [源码测试版] — 2026-10-08

- 首次公开源码（source beta，提交 `bf246c2`）；此后现行源码已换代为 SwiftUI v4.3（见顶部条目）
  Initial public source beta; the current source has since moved on to the SwiftUI v4.3 tree above
