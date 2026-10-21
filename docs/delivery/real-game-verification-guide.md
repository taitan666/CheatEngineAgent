# 真实游戏验证操作指引

**状态：** 待执行（需要真实游戏环境 + 授权样本）
**前置：** Phase 0 自进程 mock 闭环已打通（`test_field_command_flow.pas` PASS）

---

## 为什么当前未完成真实游戏验证

1. Steam 库里的独立单机游戏（《Stardew Valley》《空洞骑士》《泰拉瑞亚》等）**均已卸载**，只残留存档/云同步文件，无 `.exe`。
2. 当前**没有正在运行的游戏进程**。
3. 无授权样本（游戏内存中的字段地址/结构未知）。

这三个条件缺一不可：**已安装的游戏 + 正在运行 + 授权样本**。

---

## 当具备真实游戏环境时的执行步骤

### 前置：选定一款合适的目标

选择标准（PRD + Phase 0 计划）：
- 独立单机、离线、玩家有权修改
- 无内核级反作弊（EAC/BattlEye/Vanguard 排除）
- 数值明文存储（HP/金币等 dword/float，非加密/压缩/服务器权威）
- 优先 C++ 原生（地址稳定）或已知 .NET/Mono 结构

**推荐候选（按优先级）：**
1. 《空洞骑士》(Hollow Knight) — C++ 原生、数值明文、地址稳定、无反作弊
2. 《星露谷物语》(Stardew Valley) — 64 位 .NET/Mono、数值明文、无反作弊（但地址可能受 GC 影响）
3. 《泰拉瑞亚》(Terraria) — C#/.NET、数值明文、无反作弊

### 执行步骤

1. **启动游戏**，进入可观察数值的场景（如角色有 HP、金币）。
2. **附加进程**：用现有 `TCEAWin32ReadOnlyBackend.ListProcesses` + `AttachReadOnly` 定位游戏 PID。
3. **定位字段地址**：用现有 AOB/精确值扫描（`cea_scan_capability`）定位目标字段（如「当前金币」），或用已知基址+偏移。
4. **定义字段**：把扫描结果映射为 `TCEAGameField`（`FieldId/DisplayName/ValueType/AddressHex`），`Access=faVerifiedWritable`（需先验证可写）。
5. **打通闭环**：复用 `TCEAStateCaptureService.CaptureField` + `TCEAFieldCommandBus.ExecuteWrite`，验证「采集→写入→重读」。
6. **记录技术限制**：地址是否稳定、是否需指针链、GC 是否影响、游戏是否覆盖写入（更新 `phase0-notes.md`）。

### 关键风险（实测必须回答）

- 地址是否随重启/更新变化？→ 需基址+多级指针链（`cea_ct_draft` 已支持 pointer_chain 类型）
- 值是否被游戏覆盖（派生值/缓存）？→ 写入后短时观察（`ExecuteWrite` 已做独立重读，`coOverwritten` 分支）
- .NET 托管堆地址是否受 GC 移动？→ 若不稳定，切换 C++ 原生游戏

---

## 无需真实游戏即可继续的工作

真实游戏验证阻塞，但以下工作**不依赖游戏环境**，可并行推进（Phase 1）：

1. **副屏 UI Schema Runtime**（`cea_ui_schema_runtime.pas`）—— 用 mock 字段模型生成副屏网页
2. **LLM 结构化输出**（改造 `cea_llm_provider` 等）—— 让 AI 产出字段映射/UI Schema JSON
3. **Game Profile 持久化**（`cea_profile_service.pas`）—— 保存/加载字段模型 + 版本指纹
4. **把字段模型/Command Bus 接入主程序**（`cea_application_runtime` + 主 UI）
