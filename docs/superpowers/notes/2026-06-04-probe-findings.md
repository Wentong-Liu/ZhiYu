# Phase 1 可行性探针结论（2026-06-04）

真机环境：macOS 26.5、微信 Mac 4.x（原生 AppKit，**非 Electron**）、ZhiYu 配稳定签名(Apple Development)后授予辅助功能。
> 原始探针数据（含聊天 PII）保存在 gitignored 的 `.local-notes/2026-06-04-wechat-ax-rawdump.md`，不入库。本文件为脱敏结论。

## 结论汇总

| 验证项 | 结论 | 说明 |
|---|---|---|
| AX 读取消息 | ✅ **可行（优秀）** | 消息在右侧 `AXSplitGroup → AXScrollArea → AXTable → AXRow → AXCell → AXUnknown`，每条 `AXValue` 直接含全文 |
| 说话人区分 | ✅ **免费且可靠** | 微信自带前缀 `「对方名说:…」` / `「我说:…」` / `「我:…」`；群聊前缀即发言人名。**无需 x 坐标启发式** |
| 联系人名 | ✅ | 右侧面板顶部 `AXStaticText`（如标题） |
| 输入框定位 | ✅ | 底部 `AXScrollArea → AXTextArea`（最初误取左上搜索框，已改为底部 composer） |
| 草稿读取 | ✅ | composer 的 `AXValue` |
| AX 写入输入框 | ✅ | `AXUIElementSetAttributeValue(composer, AXValue, ...)` 生效 |
| 粘贴兜底 | ✅ | 剪贴板 + ⌘V |
| 模拟回车发送 | ✅ | CGEvent Return（只在"文件传输助手"实测） |
| 全局快捷键 ⌥⌘R | ✅ | NSEvent 全局监听 |
| **性能** | ⚠️ **需优化（已在做）** | 朴素全树遍历 5–6s，根因见下 |

## 两个重要纠正（推翻早期假设）
1. **微信 AX 树一直可读，并非"折叠/需唤醒"**。早期"只读到 2 个节点"是因旧逻辑只收 `AXStaticText`，而消息节点是 `AXUnknown`，且当时没有全树 dump。
2. **微信 4.x（本版）是原生 AppKit**：全树无任何 `AXWebArea`，全是 `AXTable/AXRow/AXCell/AXScrollArea/AXSplitGroup`。`AXManualAccessibility`/`AXEnhancedUserInterface` 设置均返回 `-25205`(不支持)，即 wake 是空操作 → 可移除。

## 性能根因与对策
- **根因**：左侧会话列表是 `AXTable` 高约 21286px、300+ 行（全部联系人）；探针把整窗口遍历了 3–4 遍（collect / collectEditables / dumpTree / wakeWebAreas），每节点多次同步跨进程 IPC → 5–6s。
- **对策（进行中）**：只导航到**右侧会话面板** `AXSplitGroup` 读消息列表（约 40 条已渲染行），**完全不下钻左侧巨表**；每行只读 `AXValue`；正常读取不再 dump 整树（移到单独诊断按钮）；去掉 wake 整树遍历。预计降到亚秒级。

## 对 Phase 2 架构的确定性结论
- **读取主力 = 纯 AX**（路线 A 成立）；OCR（路线 C）降级为可选兜底，首版可不做。
- `WeChatReader` 设计：定位主 `AXSplitGroup` → 其直接子 `AXSplitGroup`(右侧面板) → 消息 `AXTable`（取最近 N 行，只读 `AXValue`）+ 顶部联系人 `AXStaticText` + 底部 `AXTextArea`(草稿/锚定)。
- 说话人解析：`^我说[:：]`/`^我[:：]`→me；`^(.+?)说[:：]`/`^(.+?)[:：]`→other(发言人=捕获)；纯时间行跳过。
- 插入 = AX 写 `AXValue` 优先、粘贴兜底；发送 = 模拟回车；触发 = 全局快捷键(正式版换 RegisterEventHotKey 独占)。
- 面板锚定 = composer `AXTextArea` 的屏幕 frame。
- 工程前提：沙箱关、稳定签名（否则每次重编译 TCC 授权失效）。

## 开发环境注意
- adhoc 签名会导致辅助功能授权随每次重编译失效；已通过在 Signing & Capabilities 配 Team（Apple Development 稳定身份）解决。
