# Music Bridge

Native macOS software for migrating playlists from mainstream Chinese music players, downloading locally, and explicitly importing music to a writable Rockbox or supported stock-firmware iPod. Current link recognition is limited to music.163.com and music.apple.com; other sources are not yet integrated.

## Platform
macOS 14+, SwiftUI hosted in an AppKit window, SwiftPM executable packaged as an application.

## Confirmed requirements
- The user-supplied screenshot is the sole visual authority. Preserve its Chinese copy, two-column composition, colors, typography, card sizes, input and button geometry.
- Always run against real local services and real volume detection. No demonstration mode, fixed device name, fictitious writable state, or demonstration badge. Device access can be writable, read-only, or unconfirmed; allow import only for verified writable devices.
- Offer ALAC lossless with maximum sample rates of 192 kHz (default highest) and 48 kHz. Persist the selection and pass the corresponding --alac-max argument to the downloader. Actual source quality may be lower.
- Keep downloads and iPod import separate. Never import automatically.
- Preserve the Muse backup. Use only a project-local copy of the 67108864-byte disk.
- No commits, pushes, deployment, or external account changes are requested.
- The 2026-10-16 revision adds system translucency, bounded pointer-responsive panel motion and coherent interruptible state transitions. Respect Reduce Motion, Reduce Transparency and Increased Contrast. Keep directory scans off the UI thread and preserve real device state.

## Runtime
The existing amdl executable and wrapper-lite QEMU assets are copied locally from the surviving iPod workspace. Restored disk presence does not prove that the saved Apple login is still valid.

## 原生无损导入设计草案 · 2026-10-21

已实现设备型号代码识别、沿当前卷读取的 USB 家族交叉核对、离线知识库、严格同规格规划及两阶段选择。首批识别覆盖 Video 5/5.5、Classic 2007/2008/2009，并明确拦截已识别的 nano 6 原生库。按 2026-10-21 最新用户指示，默认原生目标改为 Classic 3G（2009），导入目标为 ALAC 16bit / 44.1 或 48kHz 单/双声道；未知机型可按此默认目标规划，但不改变实际识别结果。其他已识别机型保留各自配置，冲突继续拦截。此配置不冒充 Apple 官方未公布的 ALAC 音频上限，未有实体设备播放或 DAC 输出测量。下面保留完整设计与验收边界。

原生同步已停用 high 自动转换策略：本地生成并校验 ALAC 后，要求 podkit 计划只复制，任何再次转码都会被拒绝。高规格文件在首轮之后集中选择。重采样实际检测 soxr，可用时采用 28bit 精度；否则采用 SWR 64 抽头、10 位相位、0.97 截止系数。重采样后测量峰值，只在必要时施加最小防削波衰减并记录；最终 16 位量化使用 TPDF 抖动。同规格转码不施加这些音频处理。

### 产品原则

- 默认下载可获得的最高规格，电脑原文件保留。
- 导入时先处理设备兼容的同规格无损歌曲；不静默降采样、降位深、混音或转成 AAC。
- 完成本轮兼容歌曲处理后，集中展示待转换项，由用户选择转换并继续，或本次跳过。
- Rockbox 原有功能保持独立；同一设备上出现两套文件，不代表已识别当前启动系统。
- 原生模式只面对明确支持的机型与数据库版本；未知或冲突信息不自动扩大兼容范围。

### 1. 设备身份与能力分开

设备身份包含产品家族、代数/硬件版本、型号代码、固件版本（可读时）、卷标识，以及各字段的证据来源与识别状态。优先读取设备自身的 SysInfo/SysInfoExtended，再与系统 USB 信息及引擎识别结果交叉核对。

卷名、容量、外观和用户手选型号都不能单独作为精确机型证明。改装存储容量不改变硬件型号判定；手选值单独标记为用户确认，不覆盖原始检测信息。冲突时显示候选与冲突原因，停止依赖该规格的自动转换。

能力至少分成三个判断：设备原生固件能否解码、导入引擎能否正确写库、实际播放/音频输出是否已验证。引擎返回成功或数据库可读不等于设备可播放，更不等于 DAC 按原位深和采样率输出。

### 2. 随软件提供的机型知识库

采用离线、可版本控制的数据文件，按家族、硬件版本及必要的固件条件匹配。每条能力记录保存：

- 机型匹配条件和排除条件。
- 合法音频规格组合：容器、编码、有效位深、采样率、声道；不能只存一个最大采样率。
- 数据库类型、签名/设备信息要求及已适配的引擎版本。
- 官方文档链接和适用范围；社区证据单列，不能当作官方确认。
- 实机测试的机型、固件、输入规格、测试日期和结果；区分读库、完整播放及输出测量。
- 已知限制、冲突、未验证项，以及该记录的版本。

首版只填写有依据的范围。未知规格保留为未知；一个机型通过，不推广到同系列其他硬件版本。知识库随应用版本更新，首版不增加联网自动更新。

### 3. 每首歌先分类，再选择执行器

音频检查读取真实编码、有效位深、采样率和声道，不能仅凭扩展名或下载设置判定。

| 分类 | 第一阶段处理 | 后续选择 |
| --- | --- | --- |
| 兼容 ALAC 等无损文件 | 原样复制并写库 | 无需转换 |
| 音频规格兼容，但原生不接受其编码/容器 | 生成同规格 ALAC 副本后导入 | 不改变音频采样值 |
| 位深、采样率或声道超出已知兼容范围 | 暂不导入，加入待转换清单 | 第一阶段结束后集中选择 |
| 能力未知、识别冲突或文件损坏 | 不自动导入/转换，显示具体原因 | 需要补充证据或修复文件 |
| 原本就是 AAC/MP3 等有损源 | 保留并标注有损来源，不升级冒充无损 | 兼容时可原样导入，报告中单列 |

同规格无损转换属于第一阶段允许的操作。原本有损歌曲是否原样导入，不影响“本次没有新增音质损失”的判断，但不能将整批称为全无损。

### 4. 推荐转换规则

只在用户确认后，从电脑原文件生成独立兼容副本。候选目标来自已知可用的合法规格组合；不将未知范围作为推荐。

优先保留声道、有效位深与采样率，仅改变不兼容的维度，不升频或补位深来制造更高数字。目标采样率结合源规格、设备实证和转换质量选择，不能只按整数倍或最高数值决定。若证据不足以唯一推荐，明确展示保守选项及原因。

需要重采样时使用已验证的高质量实现（候选为 FFmpeg + soxr）；降低位深时在最终量化阶段采用合适的抖动（候选为 TPDF）。具体滤波、峰值/削波处理策略需通过音频定向测试确定，不能无条件叠加归一化、EQ、增益或音效。不默认下混多声道；下混必须单列确认。

推荐输出为兼容规格 ALAC。AAC 仅作为主动选择的节省空间方案，不与兼容 ALAC 使用同一个“无损”标签。

### 5. 界面与任务流程

保留当前主界面及“自动 / 原生 / Rockbox”。设备卡增加可读机型、身份确认状态及“兼容详情”入口。详情中列出适用规格、依据和验证边界，避免将复杂知识库堆到主界面。

任务状态为：识别设备 → 检查音频 → 展示首轮计划 → 导入兼容歌曲 → 汇总待转换项 → 用户选择 → 生成兼容副本并继续导入 → 最终报告。

第一阶段结束后使用独立的汇总面板，按不兼容原因/建议目标规格分组。显示每组数量、原始规格、建议规格、改变了什么、推荐依据及必要的空间估计。提供“转换所选歌曲并继续导入”“本次跳过”；未知能力组默认不选，且不能凭推荐按钮绕过识别冲突。

不能显示“全部导入完成”后再发现待处理项。统计分别显示新增、已有、待转换、未确认、失败、用户跳过。待选择时明确显示“兼容歌曲已处理，等待选择”，不把待处理歌曲计入已导入数量。

### 6. 执行边界

知识库与音频检查先生成明确的逐曲计划；执行器只能执行该计划，不能使用不透明的通用 high 预设自行决定音质变化。若现有 podkit 接口不能保证只复制已准备好的兼容文件，应调整适配层或更换写库接口，不能以预设名称代替规格保证。

本地转换副本必须检查实际输出规格和可解码性，再进入设备写入队列。保留原下载、设备原歌曲、数据库备份及现有写入防护；空间不足或设备变化时停止相应阶段，已有成功项单独记录。重试重新读取设备状态，不把上次计划当作已完成事实。

### 7. 实施顺序与验收

1. 设备身份解析与知识库结构：先支持目标机型，未知、冲突和改装存储均有明确行为。
2. 严格无损计划器与执行约束：覆盖同规格复制/转码、不兼容分流、已有有损源标注，停用原生路径的自动 AAC 回退。
3. 两阶段界面与转换执行：用户最终选择发生在兼容歌曲处理完成后，原文件不变，目标规格清楚。
4. 先用临时库测试规则及写库，再按已确认的目标机型做经授权的实体设备测试。定向无损转码测试逐样本核对解码结果，不使用哈希；数据库读回与设备播放验收分开报告。

未完成实机验证的能力必须保持“未实机验证”；这份设计不授权初始化、格式化、恢复或改写当前连接的 iPod，也不包含提交、推送或发布。

### 8. 原生导入完整流程

- 缺库时显示“建立原生音乐库”，经用户核对机型后备份并初始化；明确传入型号及当前 USB 设备的真实硬件标识，禁止引擎的默认 Video 型号。已有数据库或孤立原生媒体文件阻止初始化，不提供格式化或强制覆盖。
- 初始化写入的型号记录单独标记为配置来源，不作为自动识别实际代数的证据；USB 家族与原始型号冲突时仍停止操作。
- 首轮与降低规格阶段共用持久任务记录，展开查看每首规格、处理原因、原文件与兼容副本。新增、已有、待转换、无法确认、未匹配和失败分别计数；中断后重新预览设备，不把旧任务当成完成事实。
- 每次写入后维护同名原生播放列表并保留源顺序；系统列表与含其他歌曲的同名列表不被覆盖。校验设备文件存在及大小、曲目总数、列表数量与顺序，备份与错误信息保留。
- 提供安全弹出、用户自行安全弹出的确认入口，以及“播放正常 / 遇到问题”记录。设备写入核对与用户实机反馈分别标记，电脑端不会自动声称已实机播放。
- On-The-Go 属于原生固件入口，普通歌单管理不承诺删除该入口。
