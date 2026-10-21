# Windows 内部构建与未来公开发布预案

当前 `CheatEngineAgent.exe` 仅是内部测试构建。构建脚本生成 `dist/internal-release-manifest.json`，列出 EXE/DLL 的相对文件名、长度、SHA-256 和 Authenticode 状态；它不是签名，也不代表 Defender 或 SmartScreen 已认可。

## 内部构建核验

```powershell
.\build\build-standalone-app.ps1
.\tools\release\test-release-manifest.ps1 -DistDirectory .\dist -ManifestPath .\dist\internal-release-manifest.json -Mode internal
```

任何文件缺失、额外 EXE/DLL、长度或哈希变化都应停止使用该包并重新构建。清单不得添加用户路径、存档、CT 原文、凭据或 MCP bearer。`-Mode public` 对当前内部未签名包必须失败。

## 告警分类和处置

- **Defender Antivirus 检测或隔离**：暂停分发，记录产品/定义版本、检测名称和 ID、文件 SHA-256，以及 Windows 安全中心“保护历史”的非敏感截图。先审查依赖和实际行为；确认误报后由维护者使用[微软软件开发者样本提交入口](https://www.microsoft.com/en-us/wdsi/filesubmission)提交同一哈希，并跟踪判定。不要要求玩家关闭实时保护、恢复隔离文件或添加排除项。
- **SmartScreen“未识别应用”**：这属于下载信誉/来源提示，不能称为 Antivirus 误报。核对签名、官方下载来源和清单哈希，按正式签名与信誉流程处理，不承诺样本提交能立即消除此提示。
- **Smart App Control 或企业策略拦截**：记录系统版本和策略类别，作为兼容性限制处理；不尝试绕过设备管理员策略。

正式发布前需单独选择渠道和可信代码签名方式，在干净的普通用户 Windows 环境完成安装/升级/卸载、全部自动化与 native UI 点击验收、最终文件安全扫描和单机游戏人工验收。`docs/delivery/verification-report.md` 中的存档目标文件原子身份替换风险、备份可删除风险以及 Gate 9 仍是独立阻断项；清单校验或签名通过不能解除它们。本预案不授权目前购买证书、上传样本或修改 Defender 配置。
