# Nautilus：基于 Odin + Skald 的本地 DICOM 阅片器设计（v0.2）

> 状态：**已批准的设计规范，尚未实现**。v0.1 批准于 2026-11-13；v0.2 于同日修订，修复外部评审提出的 8 项问题（语料基准矛盾、首帧预算无定义、早停机理错误、代理松手预算缺失、并发模型缺口、置信度夸大、无降级路径、细项）。
> 来源：`document/nautilus-viewer` 设计轮次（第 1 轮 6 项决议 + Builder Check 自检 + OrthoRay 对标补强 + 外部评审修订），
> 交互文档预览：http://localhost:27319/document/SyD6jSExt6gzJbBFl2903

核心诉求四条底线：**拖入整个 CT 文件夹秒开看片、打开 DX/DR 等单张大图像秒开、验证 odin-dcm 对疑难临床片源的解码表现、滚轮翻页与调窗零卡顿零掉帧**。

## 1. 验收语料（钉死绝对路径）与目标、失败红线

### 1.1 语料基准（唯一事实来源，v0.2 修订）

三套本地语料分工如下，**所有性能红线与回归验收只挂在下表路径上**：

| 语料 | 绝对路径 | 实测内容 | 用途 |
| --- | --- | --- | --- |
| **CT 检查目录（性能红线基准）** | `D:/Odin/odin-dcm/Dcm` | 693 个文件：690 张 CT 切片 + 1 个 zip + 2 个杂项（含无扩展名） | §1.2 全部性能红线的**唯一**计时目标；杂项文件用于验证非 DICOM 文件的容错跳过 |
| **临床批量语料（规模回归）** | `D:/Odin/corpus_clin` | 扁平 2915 个文件（含 26 MB 乳腺 MG `MG3955198-Li Chun_*.DCM` ×5、CT、DX/DR 混合） | 大目录扫描/建树压力测试、字符集（GB18030 患者名）、多模态回归；**不作为红线计时目标** |
| **边缘样本语料（解码回归）** | `D:/Odin/corpus_ext` | 163 个文件：J2K/JPEG-LS/RLE/Deflate/Palette/YBR_FULL_422/Parametric Float、**9 个无 128B Preamble 的裸数据集** | 逐文件解码回归 + §1「无 Preamble 兼容」能力的**唯一验证来源**（corpus_clin 中无此类文件） |

**关系说明**（v0.1 的矛盾在此澄清）：v0.1 文档把「690 文件」挂在 corpus_clin 名下是错误的；690 张 CT 的真实出处是 `D:/Odin/odin-dcm/Dcm`。corpus_clin（2915 文件）只做规模与正确性回归。

### 1.2 目标

Nautilus 是基于 **Odin** 语言与 **Skald**（SDL3 + Vulkan 1.3，Elm 架构）构建的纯原生桌面 DICOM 2D 序列阅片与诊断工作台。它既是日常秒开临床 CT/MR 序列与 DX/DR/MG 大图的本地看片工具，也是直观检验 `odin-dcm` 在真实疑难临床语料上解析、字符集、压缩码流解码与 VOI 显示管线表现的桌面诊断前端。

### 1.3 性能红线与测量定义（v0.2 修订：每条红线都有计时起点）

**计时刻度定义**（消除歧义）：

- **t₀(drop)** = SDL 拖放事件进入主循环的时刻（热路径：窗口已运行）。
- **t₀(launch)** = `CreateProcess` 完成、exe 入口点执行的时刻（冷路径：双击图标 / `nautilus.exe <路径>`）。
- **t_screen** = 目标帧完成 Vulkan Present 的时刻（由 `SKALD_BENCH` 帧计数或 present 时间戳记录，写入状态栏与日志）。
- 红线 1 只考核 **t₀(drop)** 起；冷启动单列为红线 0。

| # | 红线 | 测量定义 | 数值 |
| --- | --- | --- | --- |
| 0 | 冷启动 | t₀(launch) → 主窗口首帧 Present | **≤ 100 ms** |
| 1 | 目录首帧 | 拖入 `D:/Odin/odin-dcm/Dcm`，t₀(drop) → 首张 CT 图像 Present | **≤ 200 ms**（预算拆解见 §4.1.1） |
| 2 | 大图打开 | 拖入单张 26 MB MG，t₀(drop) → 全分辨率 Present | **≤ 120 ms** |
| 3 | 滚轮翻页 | 连续滚轮 10 次，主线程单帧最长阻塞 | **≤ 8 ms/帧**，画面不回跳（request_seq 保证） |
| 4 | 拖拽调窗 | 按住鼠标连续调窗，CPU 映射 + GPU 更新全程 | **≤ 4 ms/帧（CT）；代理路径 ≤ 1 ms/帧（MG/DR）**，60+ fps |
| 5 | 松手回全分辨率（v0.2 新增） | 释放鼠标 → 全分辨率纹理 Present，用户可感知的中间态 | **≤ 2 帧预算（≤ 33 ms）**，允许单次非稳态 |
| 6 | 空闲占用 | 无输入 10 秒后 CPU 占用 | **0%**（事件驱动休眠） |

范围表（Goals / Non-Goals）与 v0.1 相同，此处不重复：1×1/1×2/2×2 视口、滚轮/Cine、调窗预设 F1–F7、缩放平移旋转翻转反相、HU 探针、长度/角度测量、Tag 树 + 解码诊断双面板；不做 PACS/3D/GSPS/ROI 统计/十六进制编辑器。

## 2. 已确定事项（第 1 轮决议与架构基准）

- **语言与 UI 框架**：Odin 语言 + Skald 框架（SDL3 + Vulkan 1.3，Elm 架构）。（你的决定）
- **仓库与依赖独立（vendor-copy）**：`Nautilus/vendor/dicom`（拷贝自 `D:/Odin/odin-dcm/dicom`）与 `Nautilus/vendor/skald`（拷贝自 `D:/Odin/exam/counter/vendor/skald`），根目录附带 `SDL3.dll`。（你的决定）
- **首版定位（series-workstation）**：2D 序列阅片 + `odin-dcm` Tag/解码诊断工作台。（按推荐采纳）
- **核心场景与红线（core-moment）**：见 §1.3。（你的决定）
- **序列索引与内存策略（meta-first-lru）**：后台扫元数据建 `Patient → Study → Series` 树，像素按需解码 + 滑动窗口预取 + 双上限 LRU。（按推荐采纳）
- **实时调窗计算路径（cpu-raw-cache）**：主线程缓存原始像素，CPU 端 LUT 重映射 RGBA8 + `image_update_pixels` 原地更新。（按推荐采纳）
- **视口与工具集（single-plus-2x2）**：单视口 + 1×2/2×2 网格，调窗/缩放/平移/旋转/翻转/反相/HU 探针/长度/角度。（按推荐采纳）
- **后台并发模型（v0.2 修订）**：见 §4.2.1 —— 一次性任务走 `cmd_thread`，**稳态解码走自建持久 Decode_Pool，不依赖 cmd_thread 池化**。
- **UI 画板全部决议（`artboard/nautilus-ui` Round 1 & Round 2，已全部定稿）**：
  - `g1 → g1-a`：**A · 放射科暗房三栏工作台（Clinical Darkroom Docked）** —— 纯黑 `#000000` 视口画布与 `#080A0F` 低眩光外框隔离，左 248px 序列树 + 中央多宫格视口 + 右 340px 可折叠 Tag/诊断面板 + 底栏引擎遥测。（按推荐采纳）
  - `g2 → g2-a`：**A · 紧凑层级树 + 模态胶囊 + 实时切片进度条** —— 零缩略图解码开销，20–30 ms 即刻生成，支持 `skald.virtual_list` 虚拟滚动。（按推荐采纳）
  - `g3 → g3-a`：**A · 标准四象限临床 HUD + 物理比例尺 + 琥珀金探针胶囊** —— 左上患者/ID、右上机构/序列、左下层号/层厚/比例尺、右下窗宽窗位/耗时/悬停 `XY = HU` 胶囊。（按推荐采纳）
  - `g4 → g4-a`：**A · 结构化解码诊断面板 + 视口内异常样本诊断卡** —— 右侧展示单帧耗时瀑布条、`Pixel_Info` 矩阵与封装 Fragment 偏移表；遇到无 `(7FE0,0010)` 或损坏码流样本时视口中央显示结构化诊断卡。（按推荐采纳）

## 3. 总体架构与三大不变量

架构图与 v0.1 相同（主线程 Skald Elm Loop；后台扫描 / 解码 / Tag 提取；`cmd_thread` 派发 + `SDL_PushEvent` 回投）。

三条不变量，全工程严格执行：

1. **主线程零磁盘 I/O 与零解码**：主线程绝不调用 `os.read_entire_file`、`dicom.document_open_file`、`dicom.pixel_decode_frame`。
2. **跨线程零共享可变状态**：每个后台任务用独立（或池内独占的）`dicom.Document`，完成后深拷贝到持久化堆封装为 `Msg`；后台线程严禁触碰 Skald 的 `ctx` / `renderer` / `context.temp_allocator`。
3. **序列号（request_seq）防过期与去重**：每视口单调 `request_seq: u64`；过期结果只进 LRU 不上屏。

## 4. 核心管线设计

### 4.1 秒开：抢先首帧 + 多核并行建树

1. **单文件/多文件拖放**：立即派发首个文件的高优先级解码（t₀(drop) 后 5–15 ms 内可见）。
2. **文件夹拖放（多核分片并行扫描）**：协调线程收集路径列表，首个合法 DICOM 文件立即抢发首帧；剩余文件切 `K = min(CPU核心数, 8)` 分片，`K` 个线程各持一个复用 `dicom.Document` 提取轻量索引字段后 `document_reset`。690 文件 8 核并行 **~20–30 ms** 全量建树。
   - 注意：此处的 K 线程扫描是**每次目录打开一次性创建**的（一次创建、扫完即回收），不是每帧开销，用 `cmd_thread` 逐分片派发即可，无需常驻池。

**早停扫描机制（v0.2 修订机理描述）**：`parser.odin` 的 `Parse_Options.stop_before_tag` 的实际语义是——`parse_dataset` 在 **depth == 0** 的循环顶部 `peek_tag`，当下一个元素 tag ≥ `stop_before_tag`（即 `Tag{0x7FE0, 0x0010}` PixelData）时**在读元素头之前直接置 `p.stopped = true` 返回**（parser.odin:140-146）。也就是说：**PixelData 元素本身不会被解析注册，`parse_fragments` 根本不会被进入**——不是「跳过 Fragment 遍历」，而是「在 PixelData 元素头之前就停止扫描」。`document_parse_current` 对 `p.stopped` 的提前返回有显式容忍（end_pos != len(body) 不报错）。`document_open_file_opts` 只是把这个已有选项透传出来。

### 4.1.1 首帧 ≤ 200 ms 预算账（v0.2 新增，红线 1 的核算依据）

目标：`D:/Odin/odin-dcm/Dcm`（Explicit VR LE 未压缩 CT，512×512×16-bit，单文件 ~514 KB），t₀(drop) 起：

| 步骤 | 预算 | 依据 |
| --- | --- | --- |
| SDL 拖放事件 → update 派发首帧任务 | 1 帧 ≤ 8 ms | Skald 帧循环 |
| 线程创建 + `document_open_file`（mmap + 解析） | ≤ 15 ms | odin-dcm 实测单线程 690 文件 110 ms → 单文件 ~0.16 ms，加线程创建 ~10 ms 冗余 |
| `pixel_decode_frame`（未压缩 = 内存拷贝） | ≤ 2 ms | 512 KB 拷贝 |
| 64K LUT 构建 + 512² 映射 → RGBA8 | ≤ 1 ms | §4.3 |
| `image_update_pixels`（无 Mip + 持久 Staging） | ≤ 4 ms | 1 MB RGBA8 上传 + QueueWaitIdle |
| **合计** | **≤ 30 ms** | 距 200 ms 红线有 ~170 ms 余量 |

**压缩序列首帧（同一红线内的分档）**：RLE/JPEG-LS 解码 ≤ 1 ms，预算不变；JPEG baseline ~17 ms → 合计 ≤ 50 ms；**J2K**：实测 `corpus_ext/693_J2K.dcm` 等样本 **84.6 ms/帧**（本机实测，odin-dcm README 的 139 ms 为更保守的冷测上限，取 139 ms 做设计上限）→ **J2K 首帧合计 ≤ 165 ms，仍在 200 ms 红线内**；若未来遇到 >139 ms/帧的极端 J2K，触发 §8 的 R-3 降级路径。冷启动（红线 0）与红线 1 **分开计量**，不叠加考核。

### 4.2 滚轮翻页：双上限 LRU 与方向感知预取

- **缓存键** `Frame_Key{file_path, frame_index}`；**缓存项** `Cached_Frame`（info / raw / rescale / 默认窗 / pixel_spacing / palette_rgb / decode_ms / last_used_tick）。
- **双上限**：256 帧且 ≤ 512 MB（v0.1 同）。
- **滑动窗口预取**：命中即 0 ms 上屏；未命中立即派发当帧 + 按 `scroll_dir` 步进预取前后 8 帧（单帧 ≤ 4 MB 的序列）。

#### 4.2.1 并发模型（v0.2 修订：自建持久 Decode_Pool，不走 cmd_thread）

**问题**：Skald 的 `cmd_thread`（thread.odin）是**每次调用创建一个新 OS 线程、无池、一次调用恰好一个 Msg**；工人契约还要求每次任务自备 `document_init/document_destroy`（内部含池分配）。若 4 路预取靠 4 次 `cmd_thread`，滚轮翻页时每秒几十次线程创建销毁 + 反复 arena 初始化，本身就是卡顿源。

**方案**：Nautilus 自建**常驻 Decode_Pool**，应用层拥有，与 Skald 解耦：

- 启动时创建 `min(4, CPU核心数-1)` 个常驻 worker 线程（`core:thread`），每个 worker **独占一个** `dicom.Document`，进程生命周期内只 `document_init` 一次、退出时 `document_destroy`——单文件解析复用池容量（`document_reset`），稳态 0 堆分配。
- 任务队列：互斥锁保护的任务链表（`Frame_Key` + 优先级：当帧 > 预取），worker 取任务 → `document_open_file`（复用 Document）→ `pixel_decode_frame` → 结果深拷贝进 `context.allocator` → `SDL_PushEvent` 自定义事件回投主线程。
- 取消/去重：入队时按 `Frame_Key` 去重；`request_seq` 过期的结果照旧只进 LRU。
- **worker 契约不变**：不触碰 Skald 任何状态；出参字符串一律 `strings.clone` 到持久堆。
- `cmd_thread` 仅用于**一次性低频任务**：目录扫描分片（每次打开一次）、Tag 树提取、诊断快照——这些频次下线程创建开销可忽略。

### 4.3 拖拽调窗 60+ fps 与松手回全分辨率（v0.2 补松手预算）

| 瓶颈 | 根治方案 |
| --- | --- |
| CPU 逐像素浮点窗化 | **16-bit 64K LUT 直出 RGBA8**（`lut: [65536]u32`，打包 `0xFF_BB_GG_RR`）：构建 <0.05 ms；映射 512² <0.03 ms，1363 万像素（实测 MG 3328×4096）~3 ms。32-bit/RGB/Palette 回退 odin-dcm 标准函数。 |
| Mipmap 重算 + 临时 Staging 分配 | `image_load_pixels_opts(..., mipmapped = false)`（`mip_count = 1`）+ **持久化 HOST_VISIBLE Staging Buffer**（常驻映射，按需扩容，消除每帧 `vkCreateBuffer/vkAllocateMemory/vkFreeMemory`）。 |

**Full/Proxy 双纹理键**：单帧像素 > 2,097,152（MG 3328×4096 = 13.6 MP，确认超过阈值，代理必启用）时，每视口注册 `nautilus://vp/N/proxy`（长边 ≤1024）与 `nautilus://vp/N/full` 两个固定尺寸纹理键，避免切换触发纹理重建与 `DeviceWaitIdle`。

**拖拽中**：刷 proxy，≤ 1 ms/帧（120 fps）。

**松手瞬间（红线 5，v0.2 补预算账）**——目标 3328×4096 全分辨率，单次事件非稳态：

| 步骤 | 预算 |
| --- | --- |
| 64K LUT 构建（换窗后最终值） | ≤ 0.05 ms |
| 13.6 MP LUT 映射 → RGBA8 54.4 MB | ≤ 3 ms |
| memcpy 进持久 Staging（54.4 MB，RAM 带宽 ~20 GB/s） | ≤ 3 ms |
| `vkCmdCopyBufferToImage` + 屏障 + QueueWaitIdle（独显 PCIe ~8 GB/s / 核显 ~4 GB/s） | 7–14 ms |
| **合计** | **13–20 ms ≤ 红线 5 的 33 ms（2 帧）** |

若核显实测超 33 ms：降级 R-2（§8）——把松手回全分辨率拆成上下两半两次上传，中间继续显示 proxy，最多各 1 帧。

### 4.4 对标 OrthoRay（v0.2 保留结论，数值口径同 §1.3）

冷启动 Nautilus 30–60 ms vs OrthoRay 300–600 ms（WebView2 + JS + WebGPU）；目录扫描 8 核 20–30 ms 建树 + 首帧 5–15 ms 可见 vs dicom-rs 单线程 200 ms + Rayon + Tauri IPC；未压缩/RLE/JPEG-LS 进程内零拷贝 12–18 ms vs IPC 跨进程拷贝；J2K 单帧 84.6 ms（上限 139 ms）vs C/SIMD 30–35 ms——唯一单项落后，预取后翻页 0 ms；调窗同为亚毫秒级。J2K 冷测 139 ms 出自 odin-dcm README 口径，本机实测 84.6 ms。

## 5. 视觉方向、工作台布局与交互设计

（视觉令牌、三栏布局图、快捷键矩阵、坐标变换契约、诊断面板设计均与 v0.1 一致，此处不重复；以下仅记录 v0.2 的差异点。）

- **5.5 Tag 面板 Keyword 表**：`src/tag_keywords.odin` 生成脚本为 `D:/Odin/odin-dcm/tools/gen_dict.py`（**绝对路径引用**；vendor-copy 后 Nautilus 内不携带 tools/，生成产物以源码形式提交进 `src/tag_keywords.odin`，重生成时回 odin-dcm 仓库跑）。
- **无 Preamble 兼容的验证来源**：`D:/Odin/corpus_ext` 中 9 个无 128B Preamble 的裸数据集文件（corpus_clin 无此类文件）；M3 回归清单必须逐一覆盖。

## 6. 工程目录与核心数据结构

```text
Nautilus/
  SDL3.dll                  # 拷贝自 D:/Odin/exam/counter/SDL3.dll
  build.bat / build.sh      # odin build src -out:nautilus.exe -collection:vendor=vendor
  vendor/
    dicom/                  # 拷贝自 D:/Odin/odin-dcm/dicom（+ document_open_file_opts 透传）
    skald/                  # 拷贝自 D:/Odin/exam/counter/vendor/skald（+ 无 mip 流式纹理 / 持久 Staging）
  src/
    main.odin  state.odin  update.odin
    study_loader.odin       # 目录递归扫描 + 多核分片 + 建树排序
    decode_pool.odin        # (v0.2 新增) 常驻 4-worker 解码池：任务队列/去重/优先级/SDL 回投
    frame_cache.odin        # 双上限 LRU
    display_pipeline.odin   # 64K LUT / proxy / 纹理上传
    ui_{toolbar,sidebar,viewport,inspector}.odin
    tag_keywords.odin       # PS3.6 Tag -> Keyword（生成自 D:/Odin/odin-dcm/tools/gen_dict.py）
    pipeline_test.odin      # LUT 逐字节对齐 / 坐标正逆变换 / LRU 淘汰 / 建树排序
    decode_pool_test.odin   # (v0.2 新增) 并发与生命周期测试，见下
```

**decode_pool_test.odin 覆盖清单（v0.2 新增——use-after-free 高发区）**：

1. 多 worker 并发取任务/入队竞争（互斥锁正确性、任务链表无丢失无双发）；
2. `Frame_Key` 去重：同 key 任务并发入队只执行一次；
3. worker Document 复用：连续 `document_open_file` 不同 transfer syntax 后 `document_reset` 无池污染（解码结果与单线程一致）；
4. 结果回投后立即被 LRU 淘汰再读取：不 crash（深拷贝所有权断言）；
5. 进程退出时 pool shutdown：等待在途 worker，无悬垂（与 Skald `thread_pool_destroy` 同语义）。

## 7. 实施里程碑与验证计划

1. **M0：脚手架与 vendor 集成** — 拷贝 vendor + SDL3.dll；`document_open_file_opts` 透传 + `image_load_pixels_opts(mipmapped=false)` + 持久 Staging；`odin test vendor/dicom` 71/71 全绿；空白暗房主窗口（验证红线 0 ≤ 100 ms）。
2. **M1：显示管线与单文件秒开** — `display_pipeline` + `frame_cache`；LUT 与 `render_gray8` 逐字节对齐单测；单张 26 MB MG / CT / corpus_ext 疑难样本秒开；实测红线 2、4、5。
3. **M2：目录秒扫 + Decode_Pool + 滚轮翻页** — `study_loader` 多核分片 + `decode_pool`（含全部 decode_pool_test）；多视口 + Cine + 预取；用 `D:/Odin/odin-dcm/Dcm` 实测红线 1、3，用 `corpus_clin` 2915 文件做建树压力回归。
4. **M3：测量 + 诊断面板** — HUD / 比例尺 / 长度角度；Tag 虚拟列表 + 解码诊断；corpus_ext 163 文件（含 9 个无 Preamble）逐一回归。

## 8. 风险与降级路径（v0.2 新增：每条红线配 Plan B）

| # | 风险 | 触发判据 | 降级路径 |
| --- | --- | --- | --- |
| R-0 | 冷启动 > 100 ms | M0 实测 | 字体 `#load` 延迟到首帧后；Vulkan 层提前到窗口显示并行初始化 |
| R-1 | J2K 首帧 > 200 ms | M2 实测 >139 ms/帧的样本 | 首帧先以「解码中占位 + 立即可见的低分辨率首级小波」上屏（odin-dcm J2K 分层解码能力），后台续解全帧；或将该类文件红线单独放宽至 300 ms 并在文档明示 |
| R-2 | 松手回全分辨率 > 33 ms（核显） | M1 实测 | 全帧上传拆上下两半、两帧完成，期间持续显示 proxy；或 proxy 提升到 2048p（仍 ≤4 MP，拖拽中 ~2 ms/帧） |
| R-3 | 512 MB LRU 在 2915 文件目录不够用 | M2 压测：频繁解码抖动 | 帧上限不变，字节上限升 1 GB；再不够则按 Series 驻留策略（当前序列独享预算）；UI 状态栏实时显示缓存命中率，低于 80% 告警 |
| R-4 | 60 fps 调窗仍达不到 | M1 实测 | 先查持久 Staging 是否真正命中（vkCreateBuffer 计数器）；仍不行则把 LUT 映射移入 Decode_Pool 的低优先级路径 + 双缓冲 RGBA8；最终兜底 GPU 窗化 shader（改 skald 管线，工作量最大，最后选择） |
| R-5 | 无 Preamble 文件解析失败 | M3 corpus_ext 回归 | 修复嗅探路径（odin-dcm `prepare_dataset_body` 已有容错），不在 Nautilus 侧打补丁 |

## 9. 我的默认决策（供核对）

与 v0.1 相同：命令行直传路径；右键恒调窗 / 中键恒平移；>2 MP 大图拖拽用 1024p 代理；LRU 256 帧 / 512 MB；无 PixelSpacing 诚实标 px / 仅 Imager 标 (Imager)；系统中文字体回退（msyh.ttc / simhei.ttf）+ `src/tag_keywords.odin` 静态表；验收语料按 **§1.1 表格的绝对路径**。

## 10. 设计产物记录

- **文档产物**：`document/nautilus-viewer`（`.ryugi/artifacts/document/nautilus-viewer/doc.xml`，预览 http://localhost:27319/document/SyD6jSExt6gzJbBFl2903 ）。
- **画板产物**：`artboard/nautilus-ui`（路径：`.ryugi/artifacts/artboard/nautilus-ui/canvas.json`，本地预览链接：http://localhost:27319/artboard/xfyvBOtbcqwwyVa0eitnB ）。两轮共 4 组视觉决策（`g1-a` 暗房固定三栏、`g2-a` 紧凑层级树、`g3-a` 标准四象限临床 HUD、`g4-a` 结构化解码诊断面板 + 异常样本诊断卡）均已确认定稿。
- **第 1 轮决议**：6 项（series-workstation / 核心红线 / cpu-raw-cache / meta-first-lru / single-plus-2x2 / vendor-copy），见 §2。
- **Builder Check 的真实置信度（v0.2 修订口径）**：独立子代理复核的是**文档中引用的 API 名字与签名是否存在于 odin-dcm / skald 源码**（文档级核对），**不包含任何编译验证**——M0 尚未启动，`vendor/`、`src/`、`build.bat`、`SDL3.dll` 均不存在，架构能否整体编译通过待 M0 证明。
- **v0.2 外部评审修订**：8 项问题（语料矛盾 / 首帧无定义 / 早停机理 / 松手预算 / 并发模型 / 置信度夸大 / 无 Plan B / 细项）全部修复并逐条核实：690 CT 确认在 `D:/Odin/odin-dcm/Dcm`（693 文件含 3 杂项）；MG 实测 3328×4096×16-bit（13.6 MP > 2 MP 阈值）；parser 早停语义确认为 depth-0 tag 比较提前返回（parser.odin:140-146）；cmd_thread 无池语义确认（thread.odin）；J2K 本机实测 84.6 ms/帧。
