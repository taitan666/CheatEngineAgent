# CE 文件下载 + AI 游戏识别 + 中文翻译 功能设计

**日期：** 2026-10-19
**状态：** 功能设计（已定稿，**Phase A–D 已实现**）
**目标：** 在 CheatEngineAgent 中集成 Game-Cheats-Manager（GCM）的 CE 文件目录能力，支持 AI 识别游戏、搜索对应 CE 文件、并把 CE 中的修改描述翻译成中文。

> **优先级说明**：本功能是独立增量，不阻塞主线（AI 副屏 / 金手指 / 存档 / 事件录像）。基础功能（Phase 1）完成后再实现。

---

## 1. 需求概述

用户在游戏运行时，软件能：
1. **识别当前游戏**（进程名 → 游戏名，确定性匹配 + 可选 LLM 语义识别）
2. **搜索对应 CE 文件**（在 GCM 目录中查找该游戏的 cheat table）
3. **下载 CE 文件**（.ct 文件，保存到本地）
4. **翻译修改描述**（CE 里 `<CheatEntry><Description>` 的英文 → 中文，LLM 翻译）

---

## 2. 数据源（已实测确认）

### 2.1 GCM 目录数据（游戏 → CE 下载地址）

**位置**：`%APPDATA%\GCM Settings\db\cheat_table.json`（537 KB，约 13000+ 条目）

**结构**（JSON 数组）：
```json
{
    "game_name": "Grimshire",
    "origin": "the_cheat_script",
    "official_url": "https://www.thecheatscript.com/2026/01/grimshire.html",
    "gcm_url": "GCM/Cheat Tables/Grimshire Trainer.ct",
    "version": "2026.01.16"
}
```

字段：
- `game_name`：游戏英文名（搜索主键）
- `gcm_url`：**CE 文件下载相对路径**（如 `GCM/Cheat Tables/Grimshire Trainer.ct`）
- `version`：版本
- `official_url`：官方页面（来源标注）
- `origin`：来源（the_cheat_script 等）

### 2.2 游戏名翻译（英 → 中）

**位置**：`%APPDATA%\GCM Settings\db\translations.json`（380 KB，约 16000 条目）

**结构**：
```json
{
    "en_US": "7 Days to Die",
    "zh_CN": "七日杀",
    "steam_id": 251570
}
```

字段：`en_US`（英文名）、`zh_CN`（中文名）、`steam_id`（Steam AppID，可选）。

### 2.3 下载的 CE 文件

**位置**：`%APPDATA%\GCM Trainers\<游戏目录>\*.ct`

CE 文件是 XML（CheatTable 格式），修改描述在 `<CheatEntry><Description>` 字段：
```xml
<CheatEntry>
  <ID>9418</ID>
  <Description>"SULFUR v0.9.0 | Cheat Engine Table v1.0 | 2024-10-30 ColonelRVH"</Description>
  <Color>B14D00</Color>
  <GroupHeader>1</GroupHeader>
</CheatEntry>
```

---

## 3. 关键约束（沿用项目永久边界）

1. **下载的 CE 文件是不受信任的观察**，只做解析/展示/翻译，**绝不自动执行**（现有 `cea_ct_parser` 已实现「脚本只解析不执行」）。
2. **翻译结果是辅助信息**，不是游戏事实，不授予任何权限。
3. **不绕过反作弊、不下载多人游戏作弊**——沿用 `single-player-only` 策略，仅对授权单机离线目标。
4. **LLM 翻译受现有预算约束**（prompt/RAG/output 预算、token 总量校验、不重试超时/取消）。

---

## 4. 架构设计

### 4.1 数据流

```
运行中的游戏进程
  → 进程名（如 "hollow_knight.exe"）
  → 游戏识别（进程名匹配 + translations.json steam_id）
  → 游戏英文名（如 "Hollow Knight"）
  → 查 cheat_table.json → 找到 gcm_url
  → 下载 .ct 文件（到本地 GCM Trainers 目录或项目目录）
  → 解析 <CheatEntry><Description>
  → LLM 翻译（英文 → 中文）
  → 展示中文修改描述
```

### 4.2 新增组件

```
src/
├── domain/
│   └── gcm/
│       ├── cea_gcm_types.pas        # TCEACheatTableEntry（game_name/gcm_url/version/origin）
│       └── cea_gcm_ports.pas        # ICEACheatTableCatalog（目录查询接口）
├── core/
│   └── gcm/
│       ├── cea_gcm_catalog.pas      # 读 cheat_table.json + translations.json，构建可搜索目录
│       ├── cea_gcm_download.pas     # 下载 .ct 文件（HTTP/HTTPS，受控主机 + 大小限制）
│       └── cea_gcm_translate.pas    # LLM 翻译 CE 描述（复用 cea_llm_provider）
└── infrastructure/
    └── cea_gcm_json_store.pas       # 读写 GCM 目录数据（复用 JSON 解析）
```

### 4.3 复用现有能力

| 现有能力 | 复用方式 |
|---|---|
| `cea_win32_engine_runtime` / `cea_process_capability` | 进程枚举 → 游戏进程名 |
| `cea_ct_parser` | 解析 .ct XML，提取 `<Description>`（已支持 XXE 防护 + 预算） |
| `cea_ct_catalog` | 拼音/模糊搜索（可复用于游戏名搜索） |
| `cea_llm_provider` / `cea_openai_compatible` / `cea_anthropic_compatible` | LLM 翻译（需扩展结构化输出或纯文本翻译） |
| `cea_schema_validator` | 校验 cheat_table.json 结构 |

---

## 5. 功能模块设计

### 5.1 游戏识别（进程名确定性匹配，已选定）

**输入**：进程名（如 `hollow_knight.exe`）

**匹配流程**：
1. 从进程名去掉 `.exe`，得到 `hollow_knight`
2. 在 `cheat_table.json` 里模糊匹配 `game_name`（用现有 `cea_ct_catalog` 的拼音/模糊搜索，或 rapidfuzz 风格）
3. 用 `translations.json` 的 `steam_id` 辅助（如果进程能关联 Steam AppID）
4. 匹配结果：游戏英文名 + 中文名 + 候选 CE 文件列表

**产出**：`TCEAGameMatchResult`（game_name、zh_name、steam_id、候选 cheat tables）

### 5.2 CE 文件获取（下载来源待定，见 §7.1）

**输入**：`gcm_url`（相对 filePath）+ 目标目录

**三种候选方案**（需在实现时选定，§7.4-1）：

- **方案 A（本地复用）**：读 `%APPDATA%\GCM Trainers\` 下 GCM 已下载的 .ct 文件。离线可用、零 API 依赖，但只覆盖已下载过的游戏。
- **方案 B（official_url 爬取）**：从 `cheat_table.json` 的 `official_url`（如 thecheatscript.com）爬取 CE 文件。覆盖全，但需网络爬虫 + 合规确认。
- **方案 C（用户手动）**：用户在 GCM 里下载，本软件只读本地结果。

**通用下载安全约束**（无论选哪个方案）：
1. 下载到临时文件，校验大小限制（如 ≤ 10 MB）
2. 计算 SHA-256
3. 原子发布到目标目录
4. 生成 `gcm_info.json` 元数据（game_name、version、sha256、来源）
5. 沿用 `catalog-contract.md` 的安全要求（HTTPS 白名单、大小限制、SHA-256、不信任下载内容）

### 5.3 翻译修改描述（LLM，已选定）

**输入**：CE 文件的 `<CheatEntry><Description>` 英文列表

**流程**：
1. 用 `cea_ct_parser` 解析 .ct，提取所有 `Description`
2. 批量或逐条调用 LLM 翻译（英文 → 中文）
3. 受现有 LLM 预算约束（token 上限、不重试、可取消）
4. 产出「英文描述 → 中文翻译」映射，展示给用户

**约束**：
- 翻译结果标注为「AI 翻译，仅供参考」，不是权威
- 不翻译脚本正文（AA/Lua），只翻译 Description 描述文本
- 沿用 LLM 的安全提示（拒绝多人/反作弊相关）

---

## 6. 数据源定位（关键实现细节）

### 6.1 数据目录发现

GCM 数据在用户 AppData，不在 Portable 程序目录：
```
%APPDATA%\GCM Settings\db\cheat_table.json   ← 游戏→CE 目录
%APPDATA%\GCM Settings\db\translations.json  ← 游戏名英译中
%APPDATA%\GCM Trainers\                     ← 下载的 CE 文件
```

CheatEngineAgent 需要：
1. 探测 `%APPDATA%\GCM Settings\db\cheat_table.json` 是否存在
2. 若存在，加载为目录数据源
3. 若不存在，提示用户安装/运行一次 GCM，或从 GitHub 拉取目录

### 6.2 gcm_url 的实际含义（已确认）

`gcm_url` 是 **S3 上的 filePath**（如 `GCM/Cheat Tables/Grimshire Trainer.ct`），**不是公开下载 URL**。真实下载需要 GCM 的私有签名端点 + API key（见 §7.1），本软件无法直接复用。

因此「下载」功能依赖 §7.4-1 的三种方案之一（本地复用 / official_url / 用户手动），**不能**直接拼 URL 下载。

---

## 7. 关键结论（基于 GCM 源码实测，2026-10-19）

已下载并审读 `Game-Cheats-Manager-main` 源码（`src/scripts/config.py`、`download_base_thread.py`、`search_index.py`），确认：

### 7.1 CE 文件下载：需签名 URL + 私有 API Key（无法直接复用）

- `gcm_url`（如 `GCM/Cheat Tables/Grimshire Trainer.ct`）是 **S3 上的 filePath**，不是公开 URL。
- 下载流程：`get_signed_download_url(filePath)` → `signed_get(SIGNED_URL_DOWNLOAD_ENDPOINT, params, CLIENT_API_KEY)` → 返回临时签名 URL（CloudFront）→ 下载。
- `SIGNED_URL_DOWNLOAD_ENDPOINT` 和 `CLIENT_API_KEY` 在 **`secret_config.py`**（不随源码公开，GCM 官方私有）。
- **结论**：没有 GCM 的 API key，我们无法直接调用其下载端点。可选方案：
  - (a) 复用 GCM 客户端**已下载到本地的 .ct 文件**（`%APPDATA%\GCM Trainers\`）
  - (b) 从 cheat table 的 `official_url`（如 thecheatscript.com）直接获取 CE 文件（公开网页，但需爬取）
  - (c) 用户自己在 GCM 里下载，我们只读本地结果

### 7.2 GCM 的「翻译」只翻译游戏名，不翻译 CE 描述

- `TranslationIndex`（`translations.json`）只做**游戏名** `en_US → zh_CN` 字典翻译（含拼音/模糊匹配）。
- `translate_trainer()` 生成的是 trainer 显示名（如 `[CT]《暗星铁律》修改器`），**不涉及 CE 文件内部的 `<Description>` 修改项描述**。
- **结论**：「翻译 CE 修改描述为中文」GCM 本身没有这个能力，需我们自己用 LLM 实现（你之前已选「LLM 翻译」）。

### 7.3 可复用（离线、无 API 依赖）

| 资产 | 复用方式 |
|---|---|
| `cheat_table.json`（游戏→CE 目录） | 直接读，构建游戏→CE 文件映射 |
| `translations.json`（游戏名英译中） | 直接读，游戏名中文化 |
| 搜索算法（拼音 + rapidfuzz） | 现有 `cea_ct_catalog` 已有类似能力（拼音+模糊） |
| 本地已下载的 .ct 文件 | 直接解析展示 + 翻译描述 |

### 7.4 待确认

1. **CE 文件下载来源**（§7.1）：走本地 GCM 已下载文件 / official_url 爬取 / 用户手动，需你定。
2. **LLM 翻译的模型选择**：用哪个模型？（现有 openai/anthropic 客户端，需配置 API key）
3. **翻译粒度**：逐条 Description 翻译，还是整表一次性翻译？

---

## 8. 任务拆解（实现状态）

### Phase A：GCM 目录加载与搜索（无网络依赖）— 已完成

- A1. ✅ `src/domain/gcm/cea_gcm_types.pas`：`TCEACheatTableEntry`、`TCEAGameTranslation`、`TCEAGameMatchResult`、`NormalizeProcessName`/`NormalizeGameName`/`CompactNameKey`
- A2. ✅ `src/core/gcm/cea_gcm_catalog.pas`：读 `cheat_table.json` + `translations.json`，构建内存目录
- A3. ✅ 游戏名搜索（进程名 → 游戏，`ScoreNormalizedNameMatch` 五档：100/95/80/70/token 命中率）
- A4. ✅ `tests/pascal/test_gcm_catalog.pas` → `GCM_CATALOG=PASS`

### Phase B：CE 文件获取 — 已完成（方案 C：本地复用 + 手动导入）

用户选定**方案 C**（m04701）：不做网络下载，只复用 GCM 已下载目录 + 操作者手动指定路径。理由：`gcm_url` 是 S3 filePath，真实下载需 `SIGNED_URL_DOWNLOAD_ENDPOINT` + `CLIENT_API_KEY` 签名（§7.1），复用等于内嵌他人私有凭据。

- B1. ✅ 来源选定：`cfsGcmLibrary`（`%APPDATA%\GCM Trainers\<游戏>\*.ct`）+ `cfsUserImport`（显式路径）
- B2. ✅ 三个单元：
  - `src/domain/gcm/cea_gcm_cheat_file.pas`：`TCEACheatFileSource`/`TCEACheatFileCandidate`/`TCEACheatFilePublishResult`；`CeaCheatFileMaxBytes = 16 MiB`；`CeaCheatFileLibraryDirectoryName = 'cheat-tables'`；`NormalizeCheatFilePath` 路径穿越防护
  - `src/core/gcm/cea_gcm_cheat_library.pas`：`TCEAGcmCheatLibrary`（`ScanGcmLibrary` 递归发现 + `ImportFromPath` 校验扩展名/存在/大小 + 读同级 `gcm_info.json`）
  - `src/core/gcm/cea_gcm_cheat_publisher.pas`：`TCEAGcmCheatPublisher`（SHA-256 → 临时文件 → `MoveFileExW(MoveFileReplaceExisting)` 原子发布 → `.meta.json` 元数据 → `ListPublished`）
- B3. ✅ `tests/pascal/test_gcm_cheat_library.pas` → `GCM_CHEAT_LIBRARY=PASS`（含缺失/错误扩展名/空路径/源文件消失/重发布替换）
- B4. ✅ schema：`schemas/gcm/cheat-table-file.schema.json`

### Phase C：翻译修改描述 — 已完成

- C1. ✅ 复用 `cea_ct_parser` 提取 Description（`TCEAGcmDescriptionTranslator.CollectDescriptions` 去重、跳过空白）
- C2. ✅ `src/core/gcm/cea_gcm_description_translator.pas`：`TCEAGcmDescriptionTranslator` + `TCEADescriptionBatch`，按 `MaxEntriesPerRequest`（默认 40）分批调用 `TCEALLMChatProvider.Chat`，`ResponseFormat='json_object'`
- C3. ✅ `tests/pascal/test_gcm_description_translator.pas` → `GCM_DESCRIPTION_TRANSLATOR=PASS`（10 个用例：去重、正常翻译、未知 source、缺条、provider 失败、空表、分批、畸形 JSON、取消、无 provider）

**关键设计（安全边界）**：
- **只外发 `<Description>` 文本**，Auto Assembler 与 Lua 正文永不进入 prompt；翻译结果不参与字段/地址/写入决策。
- **整批原子校验**：先校验 provider 返回的每个 `source` 必须精确匹配请求集，且条数一致，全部通过后才一次性提交；缺条、多条、未知 source、重复 source 一律整批失败（`translation_entry_count_mismatch` / `translation_source_unknown` / `translation_entry_duplicated` / `translation_response_invalid`）。理由：逐条写入会在后续条目被判定为「凭空编造」时留下半翻译状态，半翻译比不翻译更危险。
- **编码链路**：`Chat()` 返回 `{"provider_id":...,"content":"..."}` 信封，`content` 里才是模型输出的 JSON，需二次解析；解析一律走 `UnicodeString`（`TJSONObject.Get('content', UnicodeString(''))`），再用 `Utf8JsonText` 打上 CP_UTF8 标签，避免 fpjson 的 `\uXXXX` 解码缺陷与 cp936 误标签。
- **免责标注**：`CeaTranslationDisclaimer = '机器翻译，仅供参考'`，运行时 JSON 带 `disclaimer` 字段。

### Phase D：UI 集成 — 已完成

- D1. ✅ `app/lazarus/cea_main_form.pas` 的「CT RAG」页签新增「翻译描述（机器）」按钮 → `TCEAStandaloneRuntime.TranslateCheatFileDescriptions`，二次确认弹窗明确告知「只外发描述文本，脚本/地址/AOB 不外发」。
- D2. ✅ 结果 JSON 直接落到 `FCTMemo`（`source_uri` / `sha256` / `disclaimer` / `requests` / `count` / `translated` / `entries[]`）。
- D3. ✅ 独立「CE 文件库」页（玩家工作台第 6 项导航，`FSecGcm`）：搜索 GCM 目录、按进程名匹配、扫描本地已有 `.CT`、列出已发布文件、手动导入、发布到受管文件库。结果统一落 `FGcmMemo`。发布是唯一不可逆动作，因此单独二次确认；导入只校验、不改动原文件。全程不联网、不执行脚本。

> 说明：`docs/transformation-plan.md` 里「CE 下载独立页面」一项即由 D3 关闭；此后再无外观层遗留。

### 运行时接入（已完成）

`src/app/cea_application_runtime.pas` 已装配 `FGcmCatalog` / `FGcmCheatLibrary`（根目录 `DefaultGcmTrainersDirectory`）/ `FGcmCheatPublisher`（应用数据目录下 `cheat-tables`），并暴露 6 个公开 API：`LoadGcmCatalog`、`MatchGcmGame`、`SearchGcmGames`、`ScanGcmCheatFiles`、`ImportCheatFile`、`PublishCheatFile`、`ListPublishedCheatFiles`。全部本地读取，不联网、不执行。

---

## 9. 与现有架构的关系

- 本功能是 CheatEngineAgent 的**独立增量功能**，不改变现有治理内核、内存引擎、存档等核心。
- 复用的 `cea_ct_parser` 已有「脚本只解析不执行」的安全语义，CE 文件下载后同样只解析展示。
- 翻译是 LLM 的**纯文本辅助**，不涉及游戏内存写入。

---

## 10. 实现时机

- **不阻塞主线**：本功能在 AI 副屏、金手指、存档、事件录像等基础功能（Phase 1）完成后，作为独立增量实现。
- **Phase A/B/C/D 均已完成**（2026-10-20），CE 文件目录、本地文件库、描述翻译与桌面入口全部落地。
- **仍需操作者提供**（§7.4）：LLM 的模型与 API key 配置（翻译按钮在未配置时返回 `llm_not_configured`，不会静默失败）。
- 翻译粒度已定为**按批（默认 40 条/请求）**，整批原子校验。
- 主线规划见 [transformation-plan.md](transformation-plan.md)。
