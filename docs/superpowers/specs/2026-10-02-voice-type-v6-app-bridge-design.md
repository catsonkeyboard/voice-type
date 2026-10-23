# VoiceType v6 设计文档：第三方应用联动（URL scheme）

- 日期：2026-10-02（2026-10-22 由单一应用联动泛化为任意第三方应用 + 用户授权）
- 状态：已实现
- 前置：v1–v5 已交付，见同目录既有 spec

## 1. 背景与目标

其他应用（笔记、聊天客户端、agent 前端、自动化工具等）想用 VoiceType 的识别能力，但不希望结果粘贴到光标处，而是交回给自己处理。VoiceType 只负责录音与识别，把文字回传给发起请求的应用。

成功标准：

- 任意注册了自定义 URL scheme 的应用，都能用 `voicetype://` 发起、结束、取消一次听写，并在自己给出的回调地址上收到文字或失败原因。
- 用户对"哪个应用能让 VoiceType 录音"始终知情且可控。
- VoiceType 自己的快捷键听写行为不变。
- 除第一次授权弹窗外，整个过程不抢焦点、不动剪贴板。

## 2. 协议

| 方向 | URL | 含义 |
|---|---|---|
| 应用 → VoiceType | `voicetype://dictate?session=<id>&callback=<URL 编码的回调地址>` | 开始录音 |
| 应用 → VoiceType | `voicetype://stop?session=<id>` | 结束录音并识别 |
| 应用 → VoiceType | `voicetype://cancel?session=<id>` | 丢弃这次录音，不回传 |
| VoiceType → 应用 | `<回调地址>?session=<id>&text=<文字>` | 识别成功 |
| VoiceType → 应用 | `<回调地址>?session=<id>&error=<原因>` | 没有文字可给 |

示例：注册了 `myapp://` 的应用传 `callback=myapp%3A%2F%2Fvoicetype-result`，收到 `myapp://voicetype-result?session=…&text=…`。

- session 由请求方生成，1–64 个字母、数字或连字符。
- 原因：`empty`（没说话：录音太短，或只录到按键声、底噪；识别前先检查有没有至少 0.15 秒的人声）、`mic_denied`、`not_ready`（模型没装或云端没填密钥）、`busy`、`not_allowed`（用户拒绝了这个应用）、`failed`。
- 文字里除字母、数字和 `-._~` 以外的字节全部百分号编码（空格 `%20`、加号 `%2B`，按表单规则解码也不出错）。
- 文字全部放在 URL 里，不写临时文件。实测 135 KB 的 URL 也能完整送达，5 分钟听写约 14 KB。

### 2.1 回调地址要求

`dictate` 的 callback 不满足以下任一条时，整个请求被忽略（不回传，因为没有可信的地址可回）：

- 有 scheme，且不是 `http`、`https`、`file`、`ftp`、`mailto`、`sms`、`tel`、`facetime`、`voicetype`。前几类一旦允许，识别出的文字会被送进浏览器、文件或系统应用；`voicetype` 会形成回传给自己的循环。
- 不带查询、片段、用户名或密码：回传要在后面拼 `?session=…`，已有查询会把参数弄乱。
- 不超过 256 字节。

scheme 统一转成小写后作为授权记录的键，避免同一地址因大小写不同出现两条记录。

## 3. 用户授权

授权以回调地址为单位：回调地址决定了文字最终交给哪个应用。

| 回调地址的状态 | 空闲时的 `dictate` | 忙时的 `dictate` |
|---|---|---|
| 未决定 | 弹窗询问 → 记下选择 → 重新判定 | 回 `busy`，不弹窗 |
| 已允许 | 开始录音 | 回 `busy` |
| 已拒绝 | 回 `not_allowed` | 回 `not_allowed` |

- 弹窗用 `NSWorkspace.urlForApplication(toOpen:)` 找到能接收这个回调的应用，显示它的名称、图标和完整回调地址。没有应用能接收时不弹窗、不录音，直接忽略（结果无处可送）。
- 弹窗是联动里唯一会激活 VoiceType、抢焦点的地方，且每个回调地址只出现一次。
- 弹窗显示期间到达的新 `dictate` 按忙处理，不叠第二个弹窗。
- 允许与拒绝都持久化在 UserDefaults（`bridgePermissions`：回调地址 → 是否允许）。设置 → 通用 → 第三方应用 列出全部记录，可逐条移除；移除后该应用下次请求重新询问。
- `stop`、`cancel` 只作用于当前那次由同一 session 发起的录音，不需要再判断授权。

## 4. 实现

- **注册 scheme：** `project.yml` 的 `info.properties` 加 `CFBundleURLTypes`（`voicetype`）。
- **接收 URL：** `AppDelegate` 在 `applicationWillFinishLaunching` 里接管 GetURL 事件。
  - 不用 SwiftUI 的 `onOpenURL`：菜单栏面板的视图只在面板打开时存在。
  - 不用默认处理：它会顺带打开一个空的「会议转写」窗口。
- **纯逻辑：** `AppBridge.swift`。请求解析、回调地址校验、请求在各状态与授权下该做什么（`BridgeRequest.action`）、回传 URL 拼接都是纯函数。
- **授权弹窗：** `UI/BridgePermissionPrompt.swift`；授权记录存取在 `SettingsStore`。
- **输出去向：** `DictationController` 的每次听写有一个去向。
  - `cursor`：现状。
  - `external(session, callback)`：回传，不写剪贴板、不模拟 ⌘V、不引导辅助功能授权。
- **谁结束都回传：** 第三方应用发起的录音，被 `stop`、被 VoiceType 自己的快捷键、被 300 秒上限结束，结果都回传。
- **启动期间的请求：** 录音启动要等麦克风授权。这期间到达的 `stop` 或 `cancel` 先记下，取消优先于结束。启动成功后立刻执行；启动失败时，记下的是 `stop` 就回传失败原因，记下的是 `cancel` 就不回传。
- **正忙：** 正在录音、识别、润色、会议录音，或授权弹窗正在显示时，新的 `dictate` 直接回传 `busy`，不打断正在进行的事。
- **回传不抢焦点：** `NSWorkspace.OpenConfiguration.activates = false`。

## 5. 安全与隐私

- 只有用户明确允许过的回调地址能让 VoiceType 开始录音；网页、文件、邮件短信电话类地址一律不接受。
- 已知局限：URL scheme 无法可靠识别发送方。授权绑定的是"文字交给谁"（回调地址），而不是"谁发的请求"——这正是需要保护的方向：未经允许的回调永远拿不到识别文字。
- 录音期间 HUD 照常显示，系统的麦克风指示也在。
- 日志里不写识别到的文字，也不写请求 URL 的任何部分。
- 这类听写照常进历史记录，来源为 `external`。
- 和 VoiceType 自己的听写一样，最近一次送去识别的录音会保存在本机的调试文件里（`~/Library/Application Support/VoiceType/debug/last-dictation.wav`，只留最后一次），第三方应用触发的听写也在内。

## 6. 测试

- `AppBridgeTests`：请求解析、回调地址校验（可接受的自定义 scheme、被拒的 scheme、查询/片段/用户信息/超长）、scheme 小写化、回传 URL 编码与往返、六种失败原因、长文本、`dictate` 在 3 种授权 × 8 种状态下该做什么、`stop`/`cancel` 只作用于自己的会话、启动期间结束请求的合并。
- `BridgePermissionStoreTests`：授权记录的未决定、允许、拒绝与移除。
- 授权弹窗、录音、URL 往返、焦点行为靠手工验收：用一个注册了自定义 scheme 的测试应用（或 `open "voicetype://dictate?session=t1&callback=…"`）走一遍允许、拒绝、移除后重新询问。

## 7. 不做

- Windows 版的联动。
- 取消已经进入识别阶段的听写（请求方自行丢弃这次结果）。
- 按发送方（而非回调地址）授权：URL scheme 拿不到可靠的发送方身份。
