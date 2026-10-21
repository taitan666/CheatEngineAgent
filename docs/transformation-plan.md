# CheatEngineAgent 独立软件改造计划（最终版）

**基于：** PRD V1.2（`ceagent.md` / `ceagentPRD_V1.2.docx`）
**目标代码库：** `cheat-engine-agnet/`
**日期：** 2026-10-19
**关键决策（已确认，取代 2026-10-19 早前版本）：**

1. **不桥接 CE**。放弃 PRD 8.5 的「CE 引擎 + Lua Bridge + Python/MCP Adapter」外挂路线。`cheat-engine-agnet` 自带的 `cea_win32_*` 后端（进程枚举 / 只读附加 / AOB+精确值扫描 / compare-write-readback）就是**唯一的内存引擎**，软件完全独立运行。
2. **完全移除 CE 相关**。删除 `Cheat Engine/`、`DBKKernel/`、`dbvm/`、`DBVM UEFI/`、`lua/`、`scripts/`、`integration/cheat-engine/`、`references/upstream/`、`ce-unit-map.yaml` 等上游参考与桥接入口。
3. **桌面端继续用 Lazarus/Free Pascal 原生窗口**。副屏网页通过 **WebView2 或本地受限容器**嵌入，不引入 Electron/Tauri。
4. **首个真实目标 = 经典独立 RPG**（《空洞骑士》《Stardew Valley》《泰拉瑞亚》类：数值明文、无内核级反作弊、扫描/指针链友好）。以《Stardew Valley》（64 位、.NET、无反作弊、数值明文、社区已充分验证地址结构）作为 Phase 0 技术预研基准游戏。

---

## 0. 一句话结论

现有 `cheat-engine-agnet` 已经是一个**独立可运行的内存读写引擎 + 受治理写入闭环 + CT RAG + 存档工作台**，只是它是「面向内部操作者的逆向实验室」，缺少 PRD 的「玩家级产品层」。

改造的本质：**保留治理内核 + win32 引擎作为安全底座，删除 CE 相关技术债，新增「Game State Model → AI 语义映射 → UI Schema → 副屏网页 → Command Bus → 重新读取验证 → Game Profile」这一玩家产品闭环**，并用《Stardew Valley》类独立 RPG 打通首条真实闭环。

---

## 1. 仓库瘦身（决策 2 的落地清单）

### 1.1 从根目录删除

| 路径 | 处置 | 理由 |
|---|---|---|
| `Cheat Engine/` | ❌ 删除 | 上游 CE 源码，不再作为宿主或参考 |
| `DBKKernel/`、`dbvm/`、`DBVM UEFI/` | ❌ 删除 | 内核驱动/VM 调试，违反项目永久边界（kernel-driver deny），且不桥接 |
| `lua/`、`scripts/` | ❌ 删除 | CE 的 Lua/脚本扩展，随 CE 一并移除 |
| `.gitmodules` | ❌ 删除（已为空） | 无子模块引用 |

### 1.2 从 `cheat-engine-agnet/` 删除

| 路径 | 处置 | 理由 |
|---|---|---|
| `integration/cheat-engine/`（含 `ce-unit-map.yaml`、`ce_agent_registration.pas`、`ce_agent_mcp_runtime_dispatcher.pas`、`ce_agent_win32_bootstrap.pas`） | ❌ 删除 | CE 桥接入口，决策 1 明确不桥接 |
| `references/upstream/`（1479 个文件） | ❌ 删除 | 上游源码快照，不再需要 |
| `src/domain/ce/cea_ce_process_adapter.pas` | ❌ 删除 | 空壳（NotImplementedResult），真实现是 `platform/ce/cea_ce_process_capability.pas` |
| `src/domain/ce/cea_ce_memory_adapter.pas` | ❌ 删除 | 空壳 |
| `src/domain/ce/cea_ce_debug_adapter.pas` | ❌ 删除 | 空壳 |
| `src/domain/ce/cea_ce_script_adapter.pas` | ❌ 删除 | 空壳 |
| `src/mcp/cea_mcp_dispatcher.pas` | ❌ 删除 | 近空壳，真分发在别处 |
| `src/knowledge/ct/cea_ct_search.pas` | ❌ 删除 | 空壳（TCTHybridSearch），真检索是 `cea_ct_catalog.SearchText` |
| `src/llm/cea_tool_dispatcher.pas` | ❌ 删除/重写 | 空壳；PRD 需要真实的「受治理工具提案」入口 |
| `src/core/state/cea_state_kernel.pas` | ❌ 删除/替换 | 声明未实现，真持久化在 `cea_sqlite_store.pas` |
| `src/infrastructure/cea_structured_log.pas` | ❌ 删除/替换 | 空壳，PRD 需要真实操作历史日志 |
| `src/ui/cea_ui_projection.pas` | ❌ 删除/替换 | 空壳 |
| `src/platform/ce/cea_ce_command_queue.pas` | 🔧 保留但改名 | owner-thread 队列仍有价值，但「CE」前缀误导；改名 `cea_owner_thread_queue.pas` 或迁移到 `src/platform/windows/` |
| `src/platform/ce/` 下其它 `cea_ce_*` | 🔧 保留但去 CE 语义 | `cea_ce_process_capability` / `cea_ce_scan_capability` / `cea_ce_memory_read_capability` / `cea_ce_disassembly_capability` / `cea_ce_runtime_ports` / `cea_ce_effect_ports` 都是**真实实现且与 CE 无关**（它们封装的是本仓库 win32 后端），应重命名为 `cea_process_capability` / `cea_scan_capability` 等，去除误导性「ce」前缀 |
| `integration/game-cheats-manager/catalog-contract.md` | ✅ 保留 | GCM catalog 契约，是 PRD 后续「官方 API/Mod/存档」连接器可借鉴的参考，与 CE 无关 |
| `docs/superpowers/specs/2026-09-12-*`、`2026-09-12-cheat-engine-agent-*` | 📄 保留为历史 | 架构决策文档，不参与构建，作为演进记录 |

> **命名清理原则：** 决策 1 之后，`cea_ce_*` 前缀不再有「桥接 CE」的含义，所有单元名去掉 `ce` 段，改名为 `cea_<domain>_*`。`integration/` 目录整体移除后，`src/platform/ce/` 目录本身也改名为 `src/platform/engine/` 或直接并入 `src/platform/windows/`。

---

## 2. 总体架构（独立软件形态）

```
┌──────────────────────────────────────────────────────────────┐
│ CheatEngineAgent（独立 Lazarus/Free Pascal 桌面应用）           │
│                                                              │
│  桌面主窗口（原生，三栏，玩家级导航）                           │
│  ├─ 游戏概览 / 副屏页面 / 数据字段 / 金手指实验室              │
│  ├─ Game Profile / 操作历史 / 事件时间线 / 设置               │
│  └─ 底层诊断页（进程/内存、存档、LLM、MCP、关于与安全）        │
│                                                              │
│  副屏网页（WebView2 / 本地受限容器，响应式网格）               │
└──────────────────────────┬───────────────────────────────────┘
                           │ 进程内
┌──────────────────────────▼───────────────────────────────────┐
│ Game State Service + Command Bus（新增）                       │
│  语义字段模型 / 权限检查 / 命令校验 / 审计                      │
│  （复用 Governance Gateway + Effect Service）                  │
└──────────────────────────┬───────────────────────────────────┘
                           │
┌──────────────────────────▼───────────────────────────────────┐
│ 内存引擎（现有，复用，唯一引擎）                               │
│  · cea_win32_readonly_backend（进程枚举/只读附加/读内存/区域）  │
│  · cea_win32_memory_regions（VirtualQueryEx 区域枚举）          │
│  · cea_ce_scan_capability → 改名（AOB+精确值扫描，受治理）      │
│  · cea_win32_effect_backend（compare-write-readback 写原语）    │
│  · cea_win32_governed_capability_port（受治理写入 custody）     │
└──────────────────────────┬───────────────────────────────────┘
                           │ 用户授权的目标进程
                    ┌──────▼──────┐
                    │ 目标游戏进程 │  （《Stardew Valley》类独立 RPG）
                    └─────────────┘
```

**关键变化（对比早前版本）：**
- ❌ 删除「CE Lua Bridge / Python MCP Adapter / 外部 CE 进程」整条链。
- ✅ 内存引擎 = 现有 `cea_win32_*`，进程内直接调用，无 IPC。
- ✅ MCP 仍保留为**本机 loopback 诊断/控制适配器**（现有 `cea_mcp_http_server`），但不是「桥接 CE」的通道，而是独立软件的辅助接口。

---

## 3. 分阶段路线（对齐 PRD CE-0～CE-4，但去掉桥接语义）

### Phase 0 — 技术验证（独立引擎可用性 + 首个真实游戏）

**目标：** 用《Stardew Valley》（或同类）证明「独立引擎 → 状态采集 → 只读字段展示 → 一条可验证修改路径」端到端闭环。

| 编号 | 任务 | 交付物 | 验收 |
|---|---|---|---|
| P0-1 | 仓库瘦身：删除 §1 列出的 CE 相关目录/文件，去除 `cea_ce_*` 命名 | 干净仓库 | 编译通过、单测全绿 |
| P0-2 | 定义 `TCEAGameField` 语义模型 + `TCEAGameStateModel`（§4-1A） | `src/domain/state-model/` | FR-010 字段模型 |
| P0-3 | 字段级采集器：对《Stardew Valley》已知字段（金钱=明文 dword）做持续读取 + 变化检测 | `src/core/capture/` | AC-001/002 |
| P0-4 | 打通一条写入闭环：定位金钱地址 → Command Bus 校验 → compare-write-readback → 重读验证 | `src/core/command/` + 现有 win32 后端 | AC-007/015 |
| P0-5 | 记录《Stardew Valley》技术限制（.NET 运行时地址、GC 移动、是否需指针链） | `docs/delivery/phase0-notes.md` | Phase 0 退出条件 |

**退出条件（PRD 12 Phase 0）：** 只读展示闭环稳定；至少一条可验证修改路径，或明确记录目标游戏不支持安全写入的原因。

> **《Stardew Valley》技术预研要点（供 P0-3/P0-4 参考，需实测确认）：**
> - 64 位进程，Mono/.NET 运行时（不是 Win32 原生布局，地址可能受 GC 影响，需用指针链或 Mono 数据结构定位）。
> - 金钱等数值通常为明文，但可能存储在托管堆（需通过基址 + 偏移，或 .NET 结构分析）。
> - 无反作弊、无 DRM，进程可正常 `OpenProcess(VM_READ|VM_WRITE)`。
> - **风险：** 若发现地址受 GC 频繁移动，Phase 0 应切换到「基址+多级指针链」或选《空洞骑士》（C++ 原生，地址更稳定）作为备选。此项属「待验证技术问题」，不得在未实测时当作已解决。

### Phase 1 — MVP（只读副屏 + 受控修改 + AI 金手指 + Profile）

**1A. Game State Model** — `src/domain/state-model/`
- `TCEAGameField`：`field_id / label / type / value / source / confidence / access / validation_status / last_updated / constraints / evidence_refs`（对齐 PRD 8.4）
- `access` 枚举：`read_only / pending_write / verified_writable / invalid`
- `validation_status` 枚举：`observed / hypothesis / user_confirmed / verified`（对齐 FR-091 证据分级）
- 新增 `schemas/state-model/field.schema.json`、`game-state.schema.json`

**1B. State Capture** — `src/core/capture/`
- 字段级持续采集，采样预算（FR-015，P95 250ms）
- 变化检测 + 单调时钟（FR-011），产出变化事件供事件证据层复用

**1C. AI Mapping** — 改造 `src/llm/`（关键改造，见 §5）
- 新增结构化输出能力（response_format/json_object 或 tools/tool_choice）
- AI 输出的字段映射/UI Schema 一律进「待确认」态（AC-014）
- 受控产物 schema：`schemas/ui-schema/component.schema.json`、`layout.schema.json`

**1D. UI Schema Runtime** — `src/ui/cea_ui_schema_runtime.pas`
- 宿主选型：**本地回环 HTTP 服务**（`src/ui/cea_secondary_screen_host.pas`），浏览器作渲染容器；不引入 WebView2
- 组件白名单（文本/数值卡片/进度条/开关/滑块/下拉/物品格/表格/搜索框/状态提示，FR-021）
- 只读字段不得渲染可提交编辑控件（FR-022，AC-005）
- 布局持久化 + 多显示器窗口记忆与回退（FR-024/030/031/032）

**1E. Command Bus + Write Adapter** — `src/core/command/`
- 结构化命令 `field_id / target_value / expected_current_value / profile_id`（PRD 8.5.5）
- 校验链：权限 → verified_writable → 进程一致性 → 版本指纹 → 类型/范围/新鲜度 → 二次确认（FR-041/042/043/045）
- 复用 `cea_win32_effect_backend.CompareWriteReadback` 作为唯一 Write Adapter
- 两级反馈：「命令已发送」vs「状态实际改变/验证成功」（FR-044，AC-007/015）
- 区分「瞬时写入」vs「被游戏覆盖」（FR 7.4）

**1F. Game Profile** — `src/core/profile/`
- `TCEAGameProfile`：游戏标识/EXE 哈希/版本/连接器类型/字段集合/UI Schema/验证证据/最近验证/失效原因（FR-060）
- 加载前兼容性检测（FR-061），失败降级 read_only/invalid（FR-062，AC-009/016）
- 复用 SQLite，新增 profile 表

**1G. 事件录像证据层** — `src/core/events/` + `src/platform/windows/cea_win32_recording.pas`
- 循环录像缓存 / 手动标记 / 内存字段变化触发 / 事件前后片段 / 统一时间线 / 按需唤醒 AI（FR-070～080）
- 录像捕获 API、编码、默认缓存时长在 Phase 0/1 原型确定

**1H. 桌面主窗口重组** — 改造 `app/lazarus/cea_main_form.pas`
- 现有 7 Tab → 玩家级三栏导航（PRD 7.5 线框），底层诊断页保留为次级

### Phase 2 — 扩展适配
- 更多连接器（官方 API / Mod / 存档解析，存档已就绪）、字段关联分析（FR-014）、多页面（FR-033）、自然语言定制（FR-025）、批量修改（FR-047）、撤销策略（FR-048）

### Phase 3 — 生态化
- Profile 分享（脱敏 + 隐私清理 + 许可）、社区贡献、质量评价与失效报告

---

## 4. 落地文件清单（新增 + 改名 + 删除）

### 4.1 新增

```
cheat-engine-agnet/
├── src/
│   ├── domain/
│   │   ├── state-model/
│   │   │   ├── cea_field_model.pas          # TCEAGameField
│   │   │   └── cea_game_state_model.pas     # TCEAGameStateModel
│   │   └── profile/
│   │       ├── cea_profile_types.pas
│   │       └── cea_profile_ports.pas
│   ├── core/
│   │   ├── capture/
│   │   │   └── cea_state_capture_service.pas
│   │   ├── command/
│   │   │   ├── cea_command_bus.pas
│   │   │   └── cea_command_types.pas
│   │   ├── mapping/
│   │   │   └── cea_mapping_service.pas
│   │   ├── profile/
│   │   │   └── cea_profile_service.pas
│   │   └── events/
│   │       ├── cea_event_service.pas
│   │       ├── cea_recording_service.pas
│   │       └── cea_event_types.pas
│   ├── platform/
│   │   └── windows/
│   │       └── cea_win32_recording.pas      # 录像捕获（Phase 1G）
│   └── ui/
│       └── cea_ui_schema_runtime.pas        # 组件白名单渲染器
├── schemas/
│   ├── state-model/{field,game-state}.schema.json
│   ├── ui-schema/{component,layout}.schema.json
│   ├── profile/game-profile.schema.json
│   └── command/write-command.schema.json
└── docs/delivery/phase0-notes.md            # 《Stardew Valley》实测笔记
```

### 4.2 改名（去 CE 语义）

| 现有 | 改为 |
|---|---|
| `src/platform/ce/cea_ce_runtime_ports.pas` | `cea_runtime_backend_ports.pas`（`ICEAReadOnlyRuntimeBackend` 泛化为连接器后端端口） |
| `src/platform/ce/cea_ce_effect_ports.pas` | `cea_effect_backend_ports.pas` |
| `src/platform/ce/cea_ce_process_capability.pas` | `cea_process_capability.pas` |
| `src/platform/ce/cea_ce_scan_capability.pas` | `cea_scan_capability.pas` |
| `src/platform/ce/cea_ce_memory_read_capability.pas` | `cea_memory_read_capability.pas` |
| `src/platform/ce/cea_ce_disassembly_capability.pas` | `cea_disassembly_capability.pas` |
| `src/platform/ce/cea_ce_command_queue.pas` | `cea_owner_thread_queue.pas`（或迁入 `src/platform/windows/`） |
| `src/domain/ce/`（仅剩 `cea_value_scan_types.pas` 后） | `src/domain/scan/` |
| `src/app/cea_application_runtime.pas` 内 `TCEAStandaloneRuntime` 装配的 `ce_agent_*` uses | 改为新命名的引擎单元 |

### 4.3 删除（汇总，详见 §1）

`Cheat Engine/`、`DBKKernel/`、`dbvm/`、`DBVM UEFI/`、`lua/`、`scripts/`、`.gitmodules`、`integration/cheat-engine/`、`references/upstream/`、4 个 `domain/ce/*_adapter.pas` 空壳、`cea_mcp_dispatcher.pas`、`cea_ct_search.pas`、`cea_tool_dispatcher.pas`、`cea_state_kernel.pas`、`cea_structured_log.pas`、`cea_ui_projection.pas`。

---

## 5. 关键改造难点（决策 1 之后依然存在）

### 5.1 LLM 结构化输出（PRD 语义映射的硬门槛）

现有 LLM 层是**文本进文本出**，无法受约束地产出字段映射/UI Schema JSON。改造（复用 §1C）：

1. `cea_llm_provider.pas` 的 `TCEALLMChatRequest` 增加 `response_format`（json_object）或 `tools`/`tool_choice` 字段。
2. `cea_openai_compatible.pas` / `cea_anthropic_compatible.pas` 的 body 构建 + 流式/非流式解析加入结构化输出处理。
3. 重写 `cea_tool_dispatcher.pas`（现为空壳），让 AI 提案经 governance gateway 进入「待确认」态。

**Phase 0 降级路径：** 先「提示词让模型吐 JSON + 现有 `cea_schema_validator` 校验」，明确标注为降级、非最终方案。

### 5.2 语义字段模型从零新增

现有最接近的是逆向域「候选地址」（`cea_reverse_types.TCEACandidateLocation`）和 ct-draft「条目」，但都无 `field_id/label/confidence/access` 的玩家语义层。需在候选地址与语义字段之间建映射（§1A），这是「定位层」与「语义层」的桥。

### 5.3 《Stardew Valley》的内存特征（P0 实测项）

.NET/Mono 进程的托管对象地址可能受 GC 移动影响，Phase 0 需实测：
- 金钱是否稳定在固定地址，还是需要基址+多级指针链。
- 若 GC 导致地址频繁失效，Phase 0 应切换「基址+指针链」方案，或改选 C++ 原生游戏（如《空洞骑士》）。

---

## 6. 里程碑与验收映射（不变，去除桥接条目）

| 里程碑 | 关键验收用例 |
|---|---|
| CE-0（改称「独立引擎可用性」） | 进程识别、只读字段展示、断连停止命令（AC-001/011） |
| CE-1 只读副屏 | AC-001/002/003/004/011/012/017 |
| CE-2 受控修改闭环 | AC-005/006/007/008/015 |
| CE-3 AI 金手指工作流 | AC-014、自然语言目标、分轮验证、证据保存、Profile 生成 |
| CE-4 扩展评估 | AC-009/010/016 |

---

## 7. 安全与治理（决策 1 之后不削弱，反而更聚焦）

- **永久保留**：三内核边界、Lease/Epoch 失效、Effect→Approval→Receipt→Proof、策略硬否认（单机/禁训练/禁反作弊/禁内核）、模型不能签发权威、秘密不进日志、紧急停止。
- **决策 1 的增益**：删除 `DBKKernel/dbvm` 后，「kernel-driver」永久拒绝项从「代码里拦」变为「根本无此代码」，安全面收窄。
- **新增**：读写权限分离（FR-003）、默认只读 + 高风险二次确认（FR-043）、AI 生成内容校验（FR-053）、本地服务不监听公网（延续 loopback）、录像隐私（FR-080）。

---

## 8. 待验证技术问题（Phase 0 必须回答，不得当作已解决）

1. 首个游戏《Stardew Valley》的金钱/HP 地址是否稳定，还是需基址+指针链？
2. ~~WebView2 还是本地受限容器承载副屏网页？~~ **已回答**：用本地回环 HTTP 服务（`src/ui/cea_secondary_screen_host.pas`），浏览器作渲染容器，不引入 WebView2（LCL 无内建组件、自建 COM 宿主需额外运行时）。见 phase0-notes 6.11。
3. .NET 进程的结构分析是否需要额外工具，还是纯 win32 读取足够？
4. 若《Stardew Valley》地址不稳定，是否切换《空洞骑士》（C++ 原生）作为首个目标？
5. 录像捕获 API、编码、默认缓存时长与性能预算？

---

## 9. 建议的第一批执行顺序

1. **P0-1 仓库瘦身**：删除 CE 相关 + 去 `ce` 前缀改名 + 编译验证（风险低、立竿见影）。
2. **P0-2 语义字段模型**：`TCEAGameField` + `TCEAGameStateModel`（一切上层基础）。
3. **P0-3/P0-4 首条闭环**：《Stardew Valley》金钱字段「采集 → 写入 → 重读验证」。
4. **1C/1D LLM 结构化输出 + UI Schema + 副屏**：只读版副屏。
5. **1E/1F Command Bus + Game Profile**：写入闭环 + 复用。
6. **1G/1H 事件录像 + 主窗口重组**。

> 本计划为最终建议路线。技术选型（WebView2 vs 本地容器、首个游戏内存特征、录像方案）均标注「待 Phase 0 原型验证」，符合 PRD 第 19 节「技术决策状态」声明。

---

## 10. 实施状态（2026-10-21 更新）

### 已完成

| 阶段 | 内容 | 验证 |
|---|---|---|
| P0-1 仓库瘦身 | 删除 CE 上游全部内容（`Cheat Engine/`、`DBKKernel/`、`dbvm/`、`DBVM UEFI/`、`lua/`、`scripts/`、`integration/cheat-engine/`、`references/upstream/` 共 1479 文件）、去 `ce` 前缀改名、删 9 个空壳 | `PASCAL_COMPILE_SMOKE=PASS` |
| P0-2 语义字段模型 | `cea_field_model` / `cea_game_state_model` | `FIELD_MODEL=PASS` |
| P0-3/P0-4 首条闭环 | `cea_command_bus` / `cea_state_capture_service`（自进程 mock 目标） | `FIELD_COMMAND_FLOW=PASS` |
| 真实游戏验证 | 《空洞骑士》《Stardew Valley》只读附加、扫描、区域枚举；修复 128 区域上限（改按 `MaxRegions` 授权，默认 4096） | `VERIFY_SDV_ATTACH=PASS` |
| 1A/1B | 字段模型 + 采集服务 | 同上 |
| 1C AI Mapping | `cea_mapping_service`（AI 提案一律进 `msProposed` 待确认态，AC-014） | `MAPPING_SERVICE=PASS` |
| 1D UI Schema | types + codec + builder + runtime + layout store + 显示器枚举 + **副屏宿主（本地回环 HTTP）** | `UI_SCHEMA_RUNTIME=PASS` / `SECONDARY_SCREEN_HOST=PASS` 等 |
| 1E Command Bus | 结构化命令 + 校验链 + 唯一 Write Adapter + 两级反馈 | `FIELD_COMMAND_FLOW=PASS` |
| 1F Game Profile | `cea_profile_service` + SQLite 存储 + 版本兼容检测 | `PROFILE_SERVICE=PASS` / `PHASE1_E2E=PASS` |
| 1G 事件录像 | 事件类型/服务/录像缓存 + GDI BitBlt 帧源 + SQLite 事件持久化（`cea_event_repository`，含 FR-083 VACUUM 清除） | `EVENT_SERVICE=PASS` / `EVENT_REPOSITORY=PASS` |
| 1H 主窗口重组 | 7 诊断页降为次级 + 新增玩家工作台三栏（PRD 7.5） | `PASCAL_APP_COMPILE=PASS` |
| 运行时接入 | 上述全部模块接入 `cea_application_runtime`，新增玩家级 API（会话/字段/副屏/布局/事件） | `STANDALONE_APP_RUNTIME=PASS` |
| CE 下载 Phase A | `cea_gcm_types` + `cea_gcm_catalog`：加载 GCM `cheat_table.json`/`translations.json`（实测 3533 条翻译），进程名→游戏匹配、模糊搜索、中英名解析 | `GCM_CATALOG=PASS` |
| CE 下载 Phase B | `cea_gcm_cheat_file` + `cea_gcm_cheat_library` + `cea_gcm_cheat_publisher`：本地复用 `%APPDATA%\GCM Trainers` + 手动导入，SHA-256 + 原子发布 + 路径穿越防护 | `GCM_CHEAT_LIBRARY=PASS` |
| CE 下载 Phase C | `cea_gcm_description_translator`：只外发 `<Description>`，按批调用 LLM，整批原子校验 | `GCM_DESCRIPTION_TRANSLATOR=PASS` |
| CE 下载 Phase D | 「CT RAG」页签「翻译描述（机器）」入口 + 二次确认 | `PASCAL_APP_COMPILE=PASS` |
| 玩家级 MCP 工具 | 23 个新工具（会话/字段读/字段提案/字段写申请/渲染/事件/GCM/CE 文件库），registry 27 → 50；所有变更类操作返回 `rcApprovalRequired` + `local_ui_only`，MCP 无法触达 Command Bus | `MCP_PROTOCOL=PASS` / `STANDALONE_APP_RUNTIME=PASS` |
| 1D 增强：多页面/回退/定制 | `cea_ui_page_types` + `cea_ui_page_store`（SQLite `ui_schema_versions` append-only + `ui_pages`）+ `cea_ui_customization_service`（模型出页面提案，本地确认才落盘）；接入运行时（`ui-pages.sqlite3`、11 个公开 API、副屏按页面渲染 + 页内切页）+ 11 个 MCP 工具（registry 50 → 61）+ 桌面端 8 个入口 | `UI_PAGE_STORE=PASS` / `UI_CUSTOMIZATION_SERVICE=PASS` / `SECONDARY_SCREEN_HOST=PASS` / `STANDALONE_APP_RUNTIME=PASS` |
| 指针链与模块偏移 | `cea_pointer_chain`（`TCEAPointerChainSpec` + `TCEAPointerChainResolver`，语义对齐 CE `getAddress`，深度上限 8）+ `cea_win32_pointer_reader`（`OpenProcess` 只请求 `QUERY_INFORMATION or VM_READ`，每次读完即关句柄）；字段与映射层物化 `ModuleName`/`PointerOffsetsJson`/`AddressWidthBits`；运行时 `DeclarePointerField`/`ResolveFieldAddress`，且**写前/采前一律重解析**；MCP 61 → 64（含 `cea.judge_aob_uniqueness`） | `POINTER_CHAIN=PASS` / `WIN32_POINTER_READER=PASS` / `STANDALONE_APP_RUNTIME=PASS` |
| CE 文件库页面 | 玩家工作台第 6 项导航 `FSecGcm`：搜索 GCM 目录 / 按进程名匹配 / 扫描本地 `.CT` / 列出已发布 / 手动导入 / 发布到受管库；发布单独二次确认，导入只校验不改原文件 | `PASCAL_APP_COMPILE=PASS` |
| AOB 签名扫描 UI | 「进程与内存」页签新增签名行：模块名 + 签名（`48 8B ?? ??`）+「扫描签名并判定唯一性」+「重新判定唯一性」；扫描范围自动钉在该模块内（`max_regions=1`），判定结果分三态显示（唯一/零命中/歧义） | `PASCAL_APP_COMPILE=PASS` |
| 指针链字段 UI + CT 基址偏移修复 | 「游戏字段」section 新增指针链输入（模块名 / 链定义 / CT 条目键）+「从 CT 条目填入」+「声明指针链字段」（声明前二次确认）；域层新增 `ParseCTAddressExpression` 把 CE 的「地址表达式携带模块基址偏移」语义收敛成有测试的唯一实现——此前只搬 `<Offsets>` 会丢掉 `module.exe+0020` 里的 `0x20`，整条链从基址 0 解析出错误地址且不报错 | `POINTER_CHAIN=PASS`（10 条新断言）/ `PASCAL_APP_COMPILE=PASS` |
| PRD 6.9 事件分析与证据关联（FR-090~094） | 新增 `cea_event_analysis_service`：FR-090 结构化摘要（前后值/差值/方向/相关事件数）、FR-091 五级证据（`direct_observation`/`repeated_verification`/`user_confirmed`/`ai_hypothesis`/`visual_inference`，**推断级永不计入写入理由**）、FR-092 跨事件字段趋势关联、FR-093 验证建议（全部 `advisory` + `requires_approval`）；运行时 `AnalyzeEvent`/`CorrelateEventField`/`SuggestEventVerification`/`AnalyzeEventWithProvider`；MCP 新增 `cea.analyze_event`/`cea.get_field_trend`（只读）与 `cea.analyze_event_with_model`（外发数值，固定 `rcApprovalRequired`），registry 64 → 67；玩家工作台「事件时间线」新增事件列表 + 分析/关联/模型解读三个入口（模型解读单独二次确认） | `EVENT_ANALYSIS=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| PRD 6.7 Game Profile 接通（FR-055/FR-061/FR-062） | `TCEAProfileService` 此前只有单元测试、应用层零调用方（「有测试的死代码」）。补两处真实缺陷：`SaveFromModel` 只序列化 8 个字段，缺 `module_name`/`pointer_offsets_json`/`address_width_bits` → 存的是绝对地址快照、重启即失效，已补到 14 字段；`LoadForGame` 的 `BoolToStr` 第三次产出非法 JSON，改局部 `BoolToJson`。新增 `RestoreInto`：**一律 `faReadOnly` 不还原可写性、一律 `vsObserved` 不还原验证状态、`value_json` 置空不还原旧值**（上一轮的 `verified_writable` 只对那个进程那个地址有效）。运行时 `SaveGameProfile`/`RestoreGameProfile`（版本不符时把 `win32_memory` 字段降级 `faInvalid` 并计 `downgraded`，FR-062）；MCP `cea.save_game_profile`/`cea.restore_game_profile` 固定 `rcApprovalRequired`+`local_ui_only`，registry 67 → 69；「游戏字段」页新增 Profile 区块（还原前二次确认） | `PROFILE_SERVICE=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| FR-046 操作历史 | 此前 Phase 0 删掉了空壳 `cea_structured_log.pas` 就把这条需求标成「已处理」，但真实写入**从未被记账**：`WriteFieldValue` 走 CommandBus、`ConfirmFieldWritable` 直接调 `CompareWriteReadback`，两条路径都绕开治理层的 Effect/Receipt/Proof 账本。新增 `cea_write_journal_types`（`TCEAFieldWriteRecord` + 两个适配器常量把「哪条代码路径写的」变成可查询事实）+ `cea_write_journal`（SQLite `field_writes`，`sequence` 自增保序、`record_id` UNIQUE 保幂等，第六个库 `write-journal.sqlite3`）。三条设计决定：**日志失败不得把写入结果翻成「没写」**（返回 `journal_recorded:false` 但写入结果照常）、**失败与成功的写入都记**、**只记发生过的写入不记尝试过的动作**（死链探测不留账）。运行时 `ListFieldWriteHistory`；MCP `cea.list_field_write_history`（只读，registry 69 → 70，**没有对应写工具**）；「写入验证」页新增「刷新操作历史」+ 可点列表 | `WRITE_JOURNAL=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| 事件录像与按需唤醒（FR-070/074/077/079） | 录像三件套与唤醒端口此前**有实现、有测试、零装配**：`SetRecorder`/`SetWakePort` 全项目无调用，事件包 `recording_refs_json` 恒为 `[]`。补三个单元：`cea_win32_window_locator`（`EnumWindows` 按 pid 找主窗口，整条链的起点缺口——此前全项目无 `EnumWindows`/`GetWindowThreadProcessId`）、`cea_event_recording_bridge`（抓帧 + 缓存/淘汰/锁定桥成一个 `ICEARecordingCapture`，**捕获失败不登记**，否则缓存里会有磁盘上不存在的片段）、`cea_event_wake_queue`（有界 FIFO 实现 `ICEAEventWakePort`，同 id 重复入队不占新位，满队**丢最旧**并计 `DroppedCount`）。运行时 `StartEventRecording`/`StopEventRecording`/`ListRecordingSegments`/`SetRecordingSegmentLocked`/`QueueEventForAnalysis`/`PeekAnalysisQueue`；**`FFrameSource` 用类而非接口字段**（CORBA 接口不参与引用计数，用接口保存会永久泄漏帧源）。MCP 70 → 76，前三个变更类工具固定 `rcApprovalRequired`（持续读游戏画面属 FR-080 隐私范畴）；「事件时间线」页新增录像状态 + 四个按钮 + 片段列表（锁定前二次确认） | `EVENT_RECORDING_BRIDGE=PASS` / `EVENT_WAKE_QUEUE=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| FR-052 证据记录 | 此前代码侧「看起来有东西」：`cea_evidence_service.pas` 有 `Add`/`Find`，但它是**内存数组、只被单元测试引用、运行时 uses 里没有它**——与 6.22 Game Profile 同一类「有类、有测试、无调用方」。新增 `cea_field_evidence`（`TCEAFieldEvidence` + `TCEAFieldEvidenceService`，复用既有 `TCEAEvidenceKind`/`TCEAVerificationOutcome`/`TCEAEvidenceReference` 不另造枚举）+ `cea_field_evidence_store`（表 `field_evidence`，第七个库 `field-evidence.sqlite3`；同表另有 `TCEAReverseEvidenceStore` 适配 `ICEAEvidenceStore`）。与 FR-046 的分工：**FR-046 记「我做过什么」（动作），FR-052 记「凭什么这么判断」（依据）**，同一次写入两者都产生、采集只产生证据。三条硬规则：`supports_write_claim` 仅 `ekMemoryObservation`/`ekVerification` 且 `voPass`/`voInconclusive` 为真（用户陈述只命名字段、CT/反汇编是别的进程的证据、fail/unknown 是反证）；采集恒 `voPending` 而验证必须显式结论；**内容哈希种子必须含序号**，否则同值两次采集会被去重吞掉。运行时 `CaptureFieldValue` 先记录再改模型、`ConfirmFieldWritable` 成功分支记 `voPass`，新增 `ListFieldEvidence`/`RecordFieldUserConfirmation`；MCP `cea.list_field_evidence`（只读可执行）与 `cea.record_field_confirmation`（`approval_required`+`local_ui_only`，MCP 不能造证据），registry 76 → 78；「写入验证」页新增证据列表 + 「我确认这个字段就是它（留证据）」 | `FIELD_EVIDENCE=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| FR-051 分轮验证 | PRD `ceagent.md:265` 要求每轮扫描/修改前显示目的、操作和预期观察结果，此前 grep `Purpose|ExpectedObservation|分轮` 只命中 4 处无关注释——**需求写了、计划没有、代码也没有**。新增 `cea_discovery_round`（`TCEADiscoveryRound` + `TCEADiscoveryRoundService`，轮次 ID 形如 `round-00000001`）。三条设计决定：**轮次是会话内计划不落盘**（持久事实在 FR-052/FR-046）、**同一时刻只允许一个未收尾轮次**（允许并行规划等于允许「先扫了再补理由」）、**`MatchedExpectation` 必须操作者显式给出不从数值推断**（替操作者判断等于伪造验收结论）。运行时 `PlanDiscoveryRound`/`CompleteDiscoveryRound`/`AbandonDiscoveryRound`/`ListDiscoveryRounds`/`CurrentDiscoveryRound`（`EndGameSession` 时 `Reset`）；MCP 5 个工具 registry 78 → 83，规划/收尾/放弃固定 `rcApprovalRequired`（MCP 只能读不能规划），「分轮计划」页签为第 5 项导航 | `DISCOVERY_ROUND=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| FR-050 目标描述 | PRD `ceagent.md:264` 要求用户能用自然语言描述希望发现的字段，此前全项目 grep `TargetDescription|NaturalLanguage|自然语言|GoalStatement|DiscoveryGoal` 只命中 1D 的「自然语言改版 UI」（FR-025）——**这条需求从未被承接**。新增 `cea_discovery_goal`（`TCEADiscoveryGoal` + `TCEADiscoveryGoalService`，目标 ID 形如 `goal-00000001`）。三条设计决定：**目标只是意图不是证据**（`advisory` 只在模型提案时为真，且任何目标都不产生地址或可写性）、**接受目标不授权任何动作**（返回体恒带 `grants_scan:false`/`grants_write:false`）、**目标不落盘且在 `EndGameSession` 时 `Reset`**（换了游戏，「我在找金币」这句话不再指任何东西）。修掉一个真实设计缺口：`Reject` 原先只接受 `proposed`，导致「接受后发现搞错了」无法否决，改为已 `accepted` 允许被否决（否决只结束其活跃状态）。运行时 `ProposeDiscoveryGoal`/`ProposeDiscoveryGoalWithModel`/`AcceptDiscoveryGoal`/`RejectDiscoveryGoal`/`ListDiscoveryGoals`/`CurrentDiscoveryGoal`；MCP 6 个工具 registry 83 → 89，提案/接受/否决固定 `rcApprovalRequired`（意图只能由人给出）；「分轮计划」页新增目标区块（描述 + 类型/变化下拉 + 字段提示 + 记下/接受/否决 + 当前目标 + 目标列表） | `DISCOVERY_GOAL=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| FR-041 输入校验 | `ConstraintsJson` 此前在字段模型、schema、Profile 里都「存在」，唯独运行时从未读取——四处出现全是定义/序列化/注释，**比功能不完整更糟：字段上写着约束、schema 允许写，但约束从不生效**。新增 `cea_field_constraints`（`TCEAFieldConstraints` + `ParseFieldConstraints`/`IsWritableValueType`/`ValidateFieldValue`，九个稳定错误码）。六条设计规则：空 `ConstraintsJson` = 无约束不是无效、**畸形约束是错误不能静默跳过**（否则「检查过且允许」与「从未检查」无法区分，正是要修的那个 bug 的形态）、未知键拒绝（`{"maximun":100}` 会让上限静默消失）、边界按数值比较不按文本（文本比较说 `9 > 100`）、`allowed_values` 按编码字节比较（`1.5` 与 `1.50` 同值）、只接受定宽数值类型。同时补 `EncodeExactValue` 的 `integer`/`bool`（此前类型声明得出来但写不进去，每次写入报 `invalid_scan_value`）。三处写路径全部前置校验；预览里约束问题是 `blocking_reason` 而非错误结果（与 FR-045 的「冲突不是错误」同理）；`SetFieldConstraints` 在声明期解析，避免「约束存进去了但每次写入都失败」。**加约束不确认、清约束必须确认**（放宽是不可见的）；MCP `cea.set_field_constraints` 固定 `rcApprovalRequired`+`local_ui_only`（registry 90 → 91）；「写入验证」页新增约束输入框与保存/清除 | `FIELD_CONSTRAINTS=PASS` / `WRITE_PREVIEW=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |
| FR-042/FR-045 命令预览 | 此前确认框只写「将把 <字段> 写入目标值」，既不显示原值也不显示适配器，玩家在看不见要覆盖什么的情况下按「是」（`Preview|preview` 全项目零命中）。新增 `cea_write_preview`（`TCEAWritePreview` + `BuildWritePreview`）：**原值必须实时读取**（不复用模型缓存，缓存值可能几分钟前、重启后已被清空）、**冲突比较字节不比文本**（`1.5` 与 `1.50` 是同一个浮点数）、**冲突不是错误结果**（`can_execute=false` + 分级 `blocking_reason`：`field_not_verified_writable` → `original_value_unavailable` → `expected_value_changed`，返回 error 会让 UI 在最需要信息时没东西可显示）。运行时 `PreviewFieldWrite`（预览永不写入、永不改模型）；MCP `cea.preview_field_write` 可直接执行（registry 89 → 90），写本身仍走 `cea.write_field_value` 的本地审批；桌面端 `WriteSelectedField` 改为「先预览 → 按 `can_execute` 分流 → 确认框列出字段/原值/目标值/适配器 → 才写入」，冲突时提示刷新后重新确认 | `WRITE_PREVIEW=PASS` / `STANDALONE_APP_RUNTIME=PASS` / `MCP_PROTOCOL=PASS` / `PASCAL_APP_COMPILE=PASS` |

### 尚未完成

| 项 | 说明 |
|---|---|
| 副屏宿主增强 | 已用**本地回环 HTTP 服务**回答 PRD 第 19 节待验证问题 2（不引入 WebView2，零新增依赖，天然满足 FR-023 本地运行）。多页面切换已由 `SetSecondaryScreenPage` + 副屏 `/api/pages`、`/api/page` 打通（页内下拉切页）；剩余：副屏页面的富交互（当前为内联静态页 + 四个 API）、浮动小组件（FR-034）。 |
| 1D 增强项 | FR-025 自然语言定制、FR-026 页面版本回退、FR-033 多页面 **均已实现并接入运行时与 MCP**；仅剩 FR-034 浮动小组件（P2，非首版前提）。 |
| 真实写入验证 | 指针链能力已就位（模块基址 + 多级偏移求值，写前重解析），**自进程 mock 目标上已端到端打通「声明链 → 采集 → 写入 → 重读验证 → 指针重定位后仍命中」**。AOB 签名扫描已可用（模块内扫描 + 唯一性三态判定，`unique`/`not_found`/`ambiguous`），但**判定通过只说明签名可当锚点，不等于已推出该锚点对应的字段偏移链**。桌面端已能「从 CT 条目填入」现成链（含模块基址偏移），因此剩余工作从「手工推导链」变成「拿到用户真实游戏的 CT 条目」。剩余：在真实游戏上确认某个具体字段的链（从用户提供的 CT 取现成链，或由 AOB 锚点 + 反汇编手工推导）。 |
| lazbuild 完整 dist 构建 | 受 DSH 沙箱限制（lazbuild 需写 `%LOCALAPPDATA%\lazarus`）。已用 `tests/pascal/compile-app.ps1` 以 ppcx64 直接编译替代验证。 |
| MCP 工具目录刷新 | 已注册 91 个工具（`test_mcp_protocol.pas:157` 断言 `Tools.Count = 91`），但宿主（Codex 等）不会热刷新工具目录；重启后的新任务能否原生发现新工具仍需人工确认。 |

### 全量回归基线（2026-10-21）

- `tests/pascal/run-all-tests.ps1` 新增，统一扫描 `tests/pascal/test_*.pas`，输出 `SUMMARY pass=N fail=K skip=K total=T`。
- 当前结果：**`pass=76 fail=0 skip=1 total=77`**（默认沙箱）。跳过的 `test_win32_child_process.pas` 是参数化程序，由 `tests/integration/test-win32-child-process.ps1` 驱动，该集成脚本单独跑通（`WIN32_CHILD_PROCESS_INTEGRATION=PASS`）。
- **沙箱限制（非缺陷）**：workspace-write 下 `CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, <其他 pid>)` 返回 `err=5`（ERROR_ACCESS_DENIED），对自身 pid 正常。故跨进程模块枚举类测试需 Full Access 运行。
- 本轮修复的两个真实缺陷：`ReplaceFileW` 在沙箱/持有锁句柄下恒失败 → 改 `MoveFileExW` 并先释放锁（见 phase0-notes 6.8）；CT XML 导出器中文编码（见 6.2/6.9）。
- **JSON 布尔字面量（本轮新增，重要）**：`BoolToStr(Value, True)` 输出 Pascal 大小写的 `True`/`False`，**不是合法 JSON**。此前六个返回体（写入/采集/窗口放置/文件发布/副屏启动/页面保存）都带着这个缺陷，而测试用 `Pos('"verified":true', ...)` 匹配子串，从未真正命中布尔值。现统一走 `JsonBool`，测试改为 `GetJSON` + `FindPath` 取值比较。**教训：子串断言会放过格式错误的 JSON。**
- **JSON 中文编码（本轮新增，重要）**：FPC 3.2.2 的 `fpjson` 解码器 `UnescapeJSONUnicode` 无法还原任何 U+007F 以上的 `\uXXXX`（`\u661f` 变成两个 `?`，`\u661f\u9732` 变成合法 UTF-8 + `?`）。因此项目内所有 JSON 载荷一律输出**原始 UTF-8**，不用 `\uXXXX`。同时 `TCEAResult.DataJson` 是 `string`（本机 cp936），直接拼 `UTF8String` 会被转码成 GBK，故须经 `Utf8JsonText`（`SetCodePage(..., CP_UTF8, False)` 只改标签不转码）产出。`cea_gcm_types.Utf8JsonText` 是标准入口。

### 关键设计决策（实施中新增）

1. **「验证性写入」作为唯一晋升通道**：字段物化后恒为 `faReadOnly`，而 Command Bus 只接受 `faVerifiedWritable`，形成死锁。解法是以临时 `faVerifiedWritable` 视图驱动一次写入 + 独立重读，一致才写回真实可写态，不一致则置 `faInvalid`。这既解开死锁，又保证「可写」永远建立在实证之上。
2. **AI 永不直接产出可执行物**：AI 只能产出字段映射/UI Schema/扫描策略/修改建议，且一律进「待确认」态；写入只能走 Command Bus。
3. **布局/事件/Profile 各自独立 SQLite**（`ui-layout.sqlite3` / `profiles.sqlite3` / `events.sqlite3` / `governance.sqlite3`）：产品域数据与治理域数据分离，避免治理库被产品数据污染。

