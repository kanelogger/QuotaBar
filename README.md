# QuotaBar

macOS 14+ 原生菜单栏额度查询工具，集中展示：

- OpenCode Go：5 小时、UTC 周额度、按首次 Go 消息锚定的月额度。
- Kimi Code：5 小时、周额度；月额度当前显示订阅页入口。
- Codex：周剩余额度。
- DeepSeek：CNY/USD 余额和账户可用状态。

菜单栏显示所有可用指标中最紧张的一项。DeepSeek 使用可配置阈值归一化，默认 CNY ¥10、USD $2。单个平台失败不会阻断其他平台，最近一次成功值会保留并标记为旧数据。

## 工程结构

- `Sources/QuotaCore`：统一模型、并行协调器、四个平台探针、进程和网络抽象。
- `Sources/QuotaBar`：SwiftUI/AppKit 菜单栏、Keychain、浏览器 Cookie 导入、设置和本地化。
- `Tests/QuotaCoreTests`：窗口边界、解析 fixture、聚合和过期数据测试。
- `Tests/QuotaBarTests`：刷新合并和卡片渐进更新测试。
- `project.yml`：XcodeGen 工程定义。
- `Package.swift`：独立运行 QuotaCore 单元测试。

## 本地构建

要求：完整 Xcode、XcodeGen、macOS 14+。

```bash
xcodegen generate
xcodebuild -project QuotaBar.xcodeproj -scheme QuotaBar -destination 'platform=macOS' test
```

也可以只测试核心模块：

```bash
swift test
```

OpenCode 与 Codex 依赖本机 CLI。DeepSeek API Key 和手动 Kimi `kimi-auth` 保存在系统 Keychain。Kimi 在 Keychain 没有手动 Token 时会尝试从已登录浏览器读取 Cookie；该能力需要用户给 QuotaBar 完全磁盘访问权限。

## Kimi 月额度边界

Kimi Code 的 5 小时和周额度使用 `BillingService/GetUsages`。会员共享月额度位于订阅页，当前没有经过真实账号验证的稳定机器接口，因此 v1 明确显示“暂不可查询”并提供订阅页入口。代码通过 `KimiMonthlyUsageProviding` 保留独立实现接缝；只有捕获并脱敏真实只读响应、补齐 fixture 契约测试后才应启用。

应用不记录 Token、Cookie、Authorization Header 或原始私密响应。
