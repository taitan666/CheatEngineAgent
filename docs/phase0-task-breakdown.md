# Phase 0 任务拆解（可直接执行）

**基于：** [transformation-plan.md](transformation-plan.md)（最终版，决策：不桥接 CE / 删除 CE / Lazarus 原生 / 首个目标《Stardew Valley》类独立 RPG）
**日期：** 2026-10-19
**用途：** 把 Phase 0 的 P0-1～P0-5 拆成带依赖、验收、精确文件/命令的 WBS 任务。每条任务给出「验收标准」，完成即可进入下一条。

---

## 0. 前置事实（拆解依据，已实测确认）

1. **编译单元清单**：`build/unit-manifest.txt` 列出全部 **84 个单元**，其中含 3 个待删的 `integration/cheat-engine/*.pas`（第 82-84 行）。
2. **.lpi 搜索路径**（`app/lazarus/cheat_engine_agent.lpi` 第 45 行）仍引用 3 个待删/改名的目录：
   - `..\..\src\domain\ce`
   - `..\..\src\platform\ce`
   - `..\..\integration\cheat-engine`
3. **sqlite3.dll 隐藏依赖**：`build/build-standalone-app.ps1` 第 8 行从 `Cheat Engine\bin\win64\sqlite3.dll`（1311232 字节）拷贝到 `dist\`。删除 CE 目录前**必须先归档此 dll**，否则构建断链。win64 版已存在于 `dist\sqlite3.dll`，但源码仓库里仅 CE 目录有副本。
4. **空壳单元**（删除时不需改任何 uses，因为它们未被真实引用）：`cea_ce_process_adapter` / `cea_ce_memory_adapter` / `cea_ce_debug_adapter` / `cea_ce_script_adapter`（4 个 domain/ce 空壳）、`cea_mcp_dispatcher`、`cea_ct_search`、`cea_tool_dispatcher`、`cea_state_kernel`、`cea_structured_log`、`cea_ui_projection`。
5. **真实实现但需改名**的 `cea_ce_*` 单元及其**被引用点**（grep 已确认）：
   - `cea_ce_runtime_ports` ← `cea_win32_readonly_backend`、`cea_ce_process_capability`、`cea_ce_memory_read_capability`、`cea_ce_module_capability`、`cea_ce_disassembly_capability`、`cea_ce_scan_capability`
   - `cea_ce_effect_ports` ← `cea_win32_effect_backend`、`cea_win32_governed_capability_port`、`cea_freeze_service`
   - `cea_ce_process_capability` ← `cea_ce_memory_read_capability`、`cea_ce_module_capability`、`cea_ce_disassembly_capability`、`cea_ce_scan_capability`
   - `ce_agent_registration` ← `cea_application_runtime`、`cea_win32_governed_capability_port`
   - `ce_agent_win32_bootstrap` ← `cea_application_runtime`
   - `ce_agent_mcp_runtime_dispatcher` ← `cea_application_runtime`

---

## 阶段一：仓库瘦身（P0-1）

> **目标：** 删除 CE 相关 + 去 `ce` 前缀改名 + 归档 sqlite3.dll，保证 `dist/CheatEngineAgent.exe` 仍能编译通过、单测全绿。

### 任务 1.0 — 归档 sqlite3.dll（必须先做，阻塞其它删除）

- **操作：** 在 `cheat-engine-agnet/` 下新建 `vendor/sqlite3/`，把 `Cheat Engine\bin\win64\sqlite3.dll`（1311232 字节）与 `Cheat Engine\bin\win32\sqlite3.dll`（569856 字节）复制进去。**记录来源与许可证**到 `vendor/sqlite3/README.md`（SQLite 为 public domain，注明上游来源）。
- **改脚本：** `build/build-standalone-app.ps1` 第 8 行改为指向 `vendor\sqlite3\sqlite3.dll`（win64），去掉对 `Cheat Engine\` 的引用。
- **验收：** 删除 CE 目录后 `build-standalone-app.ps1` 仍能产出 `dist\CheatEngineAgent.exe` + `dist\sqlite3.dll`。

### 任务 1.1 — 删除根目录 CE 相关

- **操作：** 删除以下目录/文件（`Cheat Engine\`、`DBKKernel\`、`dbvm\`、`DBVM UEFI\`、`lua\`、`scripts\`、`.gitmodules`）。
- **注意：** 删除前确认任务 1.0 已完成（sqlite3.dll 已归档）。
- **验收：** 根目录仅剩 `.github\`、`cheat-engine-agnet\`、`Game.Cheats.Manager.Portable.2.5.0\`、`logs\`、`README.md`、`READMEes.md`、`appveyor.yml`、`.gitignore`。
  - （`Game.Cheats.Manager.Portable.2.5.0\` 是独立第三方目录，与 CE 无关，保留与否单独决策；若也要删除，可并入本任务。）

### 任务 1.2 — 删除 `integration/cheat-engine/` 与 `references/upstream/`

- **操作：** 删除 `cheat-engine-agnet/integration/cheat-engine/`（5 个文件：`ce-unit-map.yaml`、`ce_agent_registration.pas`、`ce_agent_mcp_runtime_dispatcher.pas`、`ce_agent_win32_bootstrap.pas`、`README.md`）；删除 `cheat-engine-agnet/references/upstream/`（1479 文件）。
- **保留：** `integration/game-cheats-manager/catalog-contract.md`（与 CE 无关）。
- **验收：** `integration/` 下仅剩 `game-cheats-manager/`。

### 任务 1.3 — 删除空壳单元（10 个）

- **操作：** 删除：
  - `src/domain/ce/cea_ce_process_adapter.pas`
  - `src/domain/ce/cea_ce_memory_adapter.pas`
  - `src/domain/ce/cea_ce_debug_adapter.pas`
  - `src/domain/ce/cea_ce_script_adapter.pas`
  - `src/mcp/cea_mcp_dispatcher.pas`
  - `src/knowledge/ct/cea_ct_search.pas`
  - `src/llm/cea_tool_dispatcher.pas`
  - `src/core/state/cea_state_kernel.pas`
  - `src/infrastructure/cea_structured_log.pas`
  - `src/ui/cea_ui_projection.pas`
- **验收：** 这些文件**未被任何 uses 引用**（grep 确认 `cea_state_kernel` 除外——它被 `cea_runtime.pas` 和 `cea_event_store.pas`? 需二次确认，见任务 1.5）。

### 任务 1.4 — 处理 `cea_runtime.pas` 与 `cea_state_kernel` 的关联

- **背景：** `src/core/cea_runtime.pas`（67 行，薄壳）uses `cea_state_kernel`。`cea_state_kernel.pas` 是空壳但被 `cea_runtime` 引用。两者都**未**被 `cea_application_runtime.pas`（真正的装配点）使用。
- **决策（二选一，建议 A）：**
  - **A：** 删除 `cea_state_kernel.pas` + `cea_runtime.pas`（二者都是「声明未实现」的遗留装配壳，真装配在 `cea_application_runtime`）。
  - **B：** 保留 `cea_runtime.pas`，把 `cea_state_kernel` 换为 `cea_sqlite_store`。
- **验收：** 编译通过，无残留 `cea_state_kernel` / 空壳引用。

### 任务 1.5 — 改名去 `ce` 前缀（`cea_ce_*` → 真实名）

> **原则：** 这些单元是**真实实现且与 CE 无关**（封装的是本仓库 win32 后端），`ce` 前缀是「桥接 CE」时代的误导。改名 = 改文件名 + 改 `unit X;` 声明 + 改所有 uses 引用 + 改 `unit-manifest.txt` + 改 `.lpi` 搜索路径。

| 现有文件 | 新文件名 | 新 unit 名 | 被引用点（需同步改 uses） |
|---|---|---|---|
| `src/platform/ce/cea_ce_runtime_ports.pas` | `cea_runtime_backend_ports.pas` | `cea_runtime_backend_ports` | `cea_win32_readonly_backend`、`cea_ce_process_capability`、`cea_ce_memory_read_capability`、`cea_ce_module_capability`、`cea_ce_disassembly_capability`、`cea_ce_scan_capability` |
| `src/platform/ce/cea_ce_effect_ports.pas` | `cea_effect_backend_ports.pas` | `cea_effect_backend_ports` | `cea_win32_effect_backend`、`cea_win32_governed_capability_port`、`cea_freeze_service` |
| `src/platform/ce/cea_ce_process_capability.pas` | `cea_process_capability.pas` | `cea_process_capability` | `cea_ce_memory_read_capability`、`cea_ce_module_capability`、`cea_ce_disassembly_capability`、`cea_ce_scan_capability` |
| `src/platform/ce/cea_ce_scan_capability.pas` | `cea_scan_capability.pas` | `cea_scan_capability` | （`cea_win32_readonly_backend`? 确认） |
| `src/platform/ce/cea_ce_memory_read_capability.pas` | `cea_memory_read_capability.pas` | `cea_memory_read_capability` | （确认引用点） |
| `src/platform/ce/cea_ce_module_capability.pas` | `cea_module_capability.pas` | `cea_module_capability` | （确认引用点） |
| `src/platform/ce/cea_ce_disassembly_capability.pas` | `cea_disassembly_capability.pas` | `cea_disassembly_capability` | （确认引用点） |
| `src/platform/ce/cea_ce_command_queue.pas` | `cea_owner_thread_queue.pas` | `cea_owner_thread_queue` | （确认引用点） |

**同时：** 更新 `integration/cheat-engine` 删除后，`ce_agent_registration` / `ce_agent_win32_bootstrap` / `ce_agent_mcp_runtime_dispatcher` 三个单元也随 1.2 删除，需处理 `cea_application_runtime.pas` 第 196-197 行的 uses（`ce_agent_registration, ce_agent_win32_bootstrap, ce_agent_mcp_runtime_dispatcher`）和 `cea_win32_governed_capability_port.pas` 第 10 行的 `ce_agent_registration`。

**关键决策：** `ce_agent_registration` 里的 `TCEAgentRuntime`（组合进程/内存/模块/扫描/反汇编 capability）是**真实的运行时装配器**，删除前必须把它的职责迁到新的装配点（见任务 1.6）。**不能简单删除**——它是「win32 引擎组装」的现成实现。

### 任务 1.6 — 迁移 `ce_agent_registration` 的运行时装配职责

- **背景：** `ce_agent_registration.pas` 的 `TCEAgentRuntime` 是真正的「引擎组装器」（组合 command_queue + process + memory + module + scan + disassembly capability）。它只是**文件名**带了 `ce_agent_` 前缀，**逻辑本身与 CE 无关**（封装的是 win32 后端）。
- **操作：** 把 `ce_agent_registration.pas` 的**内容**迁移为 `src/platform/windows/cea_win32_engine_runtime.pas`（或 `src/core/cea_engine_runtime.pas`），类名 `TCEAgentRuntime` 改为 `TCEAEngineRuntime`；`ce_agent_mcp_runtime_dispatcher.pas` 迁移为 `src/mcp/cea_engine_mcp_dispatcher.pas`；`ce_agent_win32_bootstrap.pas` 迁移为 `src/platform/windows/cea_win32_engine_bootstrap.pas`。
- **验收：** `cea_application_runtime.pas` 的 uses 改为新单元，编译通过，MCP 工具分发、owner-thread 队列、win32 引擎装配均正常。

### 任务 1.7 — 更新编译配置（unit-manifest + .lpi）

- **操作：**
  - 重写 `build/unit-manifest.txt`：移除 3 个 integration 单元 + 10 个空壳 + 改名的单元名。
  - 更新 `app/lazarus/cheat_engine_agent.lpi` 的 `<OtherUnitFiles>`（第 45 行）：移除 `..\..\src\domain\ce`（若目录已空）、`..\..\integration\cheat-engine`，新增改名的目录路径。
- **验收：** `lazbuild -B` 编译通过，无 missing unit 报错。

### 任务 1.8 — 回归验证

- **操作：** 运行 `build/build-standalone-app.ps1` + 现有测试（`tests/pascal/run-test-program.ps1`、`tests/acceptance/verify-scaffold.ps1`、`tools/schema-check/check-schemas.ps1`）。
- **验收：** 全绿。`dist/CheatEngineAgent.exe` 生成，`--self-test` 返回 0。

---

## 阶段二：语义字段模型（P0-2）

### 任务 2.1 — 定义 `TCEAGameField` 类型

- **文件：** 新建 `src/domain/state-model/cea_field_model.pas`
- **内容（对齐 PRD 8.4）：**
  ```
  TCEAGameField = record
    FieldId: string;        // "player.gold"
    Label: string;          // "金币"
    ValueType: string;      // integer/single/bool/enum/string
    ValueJson: string;      // 当前值（JSON 编码）
    Source: string;         // "win32_memory" / "save_file" / ...
    Confidence: Double;     // 0..1
    Access: TCEAFieldAccess;   // read_only / pending_write / verified_writable / invalid
    ValidationStatus: TCEAValidationStatus; // observed / hypothesis / user_confirmed / verified
    LastUpdated: string;    // UTC ISO8601
    ConstraintsJson: string; // 范围/枚举约束
    EvidenceRefsJson: string; // 证据引用
  end;
  ```
- **枚举：** `TCEAFieldAccess`、`TCEAValidationStatus`。
- **验收：** 单元测试 `test_field_model.pas` 能构造/校验字段，`access` 默认 `read_only`，`validation_status` 默认 `observed`。

### 任务 2.2 — 定义 `TCEAGameStateModel`

- **文件：** 新建 `src/domain/state-model/cea_game_state_model.pas`
- **内容：** 字段集合 + 版本指纹（EXE SHA256 / 模块集哈希）+ 关联关系占位（当前值/最大值、物品ID/数量、装备槽/装备对象，FR-014 占位）。
- **验收：** 单元测试能 add/get/iterate 字段，能绑定进程版本指纹。

### 任务 2.3 — 新增 JSON Schema

- **文件：** `schemas/state-model/field.schema.json`、`schemas/state-model/game-state.schema.json`
- **验收：** `tools/schema-check/check-schemas.ps1` 通过（接入现有 `cea_schema_validator`，注意其子集能力：正则仅 2 个硬编码，若字段 schema 需要新正则，需先扩展 validator）。

---

## 阶段三：字段级采集 + 首条写入闭环（P0-3 / P0-4）

### 任务 3.1 — 字段级采集器（State Capture）

- **文件：** 新建 `src/core/capture/cea_state_capture_service.pas`
- **内容：** 对已注册字段做持续读取（复用 `cea_memory_read_capability` + win32 后端），带采样预算 + 变化检测（对比上次值 + 时间戳 + 单调时钟）。
- **验收：** 对《Stardew Valley》金钱字段（明文 dword）能周期性读取并检测变化；AI 离线时仍工作（AC-011）。

### 任务 3.2 — Command Bus（字段级命令协议）

- **文件：** 新建 `src/core/command/cea_command_types.pas` + `cea_command_bus.pas`
- **内容：** 命令 = `field_id / target_value / expected_current_value / profile_id`。校验链：权限 → verified_writable → 进程一致性 → 版本指纹 → 类型/范围/新鲜度 → 二次确认（复用 governance gateway + lease/effect）。
- **验收：** 只读字段拒绝写（AC-005）；非法值拦截（AC-006）；进程切换拒绝旧命令（AC-008/013）。

### 任务 3.3 — 首条写入闭环（《Stardew Valley》金钱）

- **操作：**
  1. 定位金钱地址（用现有 AOB/精确值扫描，或已知基址+偏移）。
  2. 通过 Command Bus 提交写命令，走 `cea_win32_effect_backend.CompareWriteReadback`。
  3. 重读验证，记录「命令已发送」vs「状态实际改变」两级结果。
- **验收：** 一条端到端「采集→写入→重读验证」闭环跑通（AC-007/015）；记录地址稳定性（是否受 GC 移动）。

### 任务 3.4 — Phase 0 技术笔记

- **文件：** `docs/delivery/phase0-notes.md`
- **内容：** 记录《Stardew Valley》金钱/HP 地址稳定性、是否需基址+指针链、.NET 运行时影响、实际耗时、技术限制。
- **验收：** 文档完整，明确「Phase 0 退出条件」是否满足（只读闭环稳定 + 至少一条可验证修改路径，或记录不支持写入的原因）。

---

## 依赖关系图

```
1.0 sqlite归档 ──→ 1.1 删根目录 ──→ 1.2 删integration/references
                                     │
1.3 删空壳 ──→ 1.4 处理runtime/state ──→ 1.5 改名 ──→ 1.6 迁移装配 ──→ 1.7 更新编译配置 ──→ 1.8 回归验证
                    │
                    └──（1.3/1.4/1.5/1.6 有顺序依赖：先删空壳，再处理引用，再改名，再迁移装配，最后改配置）

阶段二（2.1→2.2→2.3）依赖阶段一完成（编译干净）
阶段三（3.1→3.2→3.3→3.4）依赖阶段二完成（有字段模型）
```

---

## 风险与提醒

1. **sqlite3.dll 是硬前置**（任务 1.0），不做就删 CE 目录会直接断构建。
2. **`ce_agent_registration.pas` 不能简单删**——它是真实的引擎装配器，须先迁移（任务 1.6）。
3. **改名是「多文件联动」操作**（任务 1.5），每个 `cea_ce_*` 改名要同步改：文件名、`unit` 声明、所有 uses 引用、unit-manifest、.lpi 搜索路径，五处一致，缺一编译失败。
4. **`cea_schema_validator` 是子集实现**（仅 2 个硬编码正则），新增字段 schema 若需要新正则，得先扩展 validator（任务 2.3 备注）。
5. **《Stardew Valley》地址稳定性未知**（.NET GC），若实测不稳定，任务 3.3 切换「基址+多级指针链」或改选 C++ 原生游戏（《空洞骑士》），此项记录到 phase0-notes。
