# Windows 发布与 Defender 告警预案

日期：2026-09-20  
状态：用户已确认，分阶段实施中  
范围：独立 Lazarus/Free Pascal 应用的构建、分发、验签与误报处置；不是在当前电脑上修改 Defender 配置

## 意图与边界

用户关心将来公开分发时程序被 Windows 安全功能拦截。目标是让发布包可核验、告警可诊断、有合法申诉流程，同时不削弱玩家设备安全。开发版可以保持本地未签名；正式发布必须经过单独的发布门禁。没有任何流程承诺“永不误报”，也不把本机一次扫描通过等同于安全认证。

Microsoft Defender Antivirus 的恶意软件/潜在有害应用检测与 Defender SmartScreen 的下载信誉提示是不同事件，必须分别记录和处置。微软说明新签名文件也可能暂时收到 SmartScreen 提示；没有可预先加入的开发者白名单。来源：[SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)、[software developer FAQ](https://learn.microsoft.com/en-us/defender-xdr/developer-faq)。

## 方案与交付门禁

发布渠道可选可信签名的直接分发，或另行评估 Microsoft Store；不在本设计中购买证书、开通账户或选择商店渠道。与“要求玩家关闭 Defender/添加排除项”相比，正式签名、可核验构建和申诉流程不降低玩家防护，因此选为唯一发布路径。最终渠道与签名服务由发布前单独确认。

`ReleaseManifest` 对每个公开版本记录源码版本/构建配置、编译器及依赖版本、EXE/安装包和随附 DLL 的 SHA-256、签名主体与时间戳、发布渠道、扫描结果、兼容系统和已知限制。发布包、安装器及其可执行依赖在签名后不得再修改。签名材料不进入源码库、日志、应用配置、MCP 输出或用户包；构建与签名权限分离。

发布流水线按以下门禁执行：

1. 从受控源码与固定依赖构建独立程序；核对清单中的所有文件，确认不捆绑原版 Cheat Engine、驱动、注入/隐蔽组件或未授权的第三方二进制。
2. 在干净 Windows 环境运行现有 Pascal/Schema/集成与 native UI 验收，并补充安装、卸载、升级、首次运行和紧急停止测试。明确检查无管理员权限默认要求、无自动添加 Defender 排除项、无暗中下载/运行 CT 脚本。
3. 选择正式发布渠道和可信代码签名方式后签名、时间戳并验证签名链；为用户发布 SHA-256 与版本说明。签名不能作为取消功能测试或安全审查的理由。若尚无符合渠道要求的签名，包只能标注为内部测试构建，不作为正式公开发布。
4. 用更新后的 Defender 定义和目标 Windows 版本扫描安装包及最终文件；区分 Antivirus 检测、SmartScreen 信誉提示、Smart App Control 或企业策略阻断。记录产品、检测名称/ID、版本、文件哈希和保护历史证据，不记录玩家存档、API 密钥或完整敏感路径。
5. 有 Antivirus 告警或无法解释的拦截时暂停该版本分发，先审查依赖与行为，再按[微软软件开发者提交渠道](https://www.microsoft.com/en-us/wdsi/filesubmission)提交相同哈希的样本并跟踪最终判定；修复真实问题后重新构建、签名和验证。SmartScreen“未识别应用”按签名与来源说明、信誉积累处理，不伪称为杀毒误报，也不承诺手工提交可立即消除消费者信誉提示。

## 应用内诊断与支持边界

设置/关于页可展示版本、发布渠道、可执行文件哈希、签名状态及“如何核验官方包”说明；不要求应用自己修改 Defender。发生告警时，帮助文档指导玩家查看 Windows 安全中心“保护历史”，核对来源与哈希，并向维护者提供检测名称、产品版本和清单哈希。诊断包默认不包含原始存档、CT 内容、绝对目录、凭据、MCP bearer 或游戏进程数据；玩家明确预览后才可导出。

软件不得自动关闭实时保护、恢复隔离文件、添加进程/目录/扩展名排除项、修改安全策略或提示玩家常规使用“允许威胁”。微软提醒排除项会降低防护：[Defender exclusion guidance](https://learn.microsoft.com/en-us/defender-endpoint/defender-endpoint-exclusions-common-mistakes)。维护者也不能把 Defender 规则规避、代码混淆或打包器当作误报解决方案。

## 发布阻断与验收

- `docs/delivery/verification-report.md` 已列出的存档目标文件原子身份替换风险、备份可删除风险、UI 点击验收和真实游戏人工验收仍须按各自 Gate 解决；签名或扫描通过不会解除这些阻断。
- 正式包的清单哈希与下载文件、签名后的文件逐一相符；篡改、缺失依赖、无效签名或扫描未决均使发布失败。
- 模拟或使用受控测试告警时，UI/帮助文档能区分 Antivirus 隔离与 SmartScreen 信誉提示；不会调用 Defender 配置或自动恢复 API。
- 误报流程能形成可追踪的提交编号、原始哈希、最终判定和重新发布决定；真实检测未获解释或复核前不建议用户绕过。
- 在干净普通用户 Windows 环境完成安装、启动、卸载和更新回归；企业策略或 Smart App Control 阻断要作为兼容性限制报告，不静默绕过。

本设计是发布预案，不表示当前机器发生了误报，也不授权现在购买证书、提交样本、修改系统安全设置或向用户分发构建。
