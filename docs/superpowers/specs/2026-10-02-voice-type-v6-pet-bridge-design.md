# VoiceType v6 设计文档：桌宠联动（URL scheme）

- 日期：2026-10-02
- 状态：已实现，待与桌宠一起验收
- 前置：v1–v5 已交付，见同目录既有 spec
- 对应的桌宠侧设计：桌宠仓库 `docs/superpowers/specs/2026-10-02-m4a-voice-design.md`

## 1. 背景与目标

桌宠（Pet）有自己的说话键。按下后由 VoiceType 录音识别，文字回传给桌宠，由桌宠当作问题提交给 agent。VoiceType 只负责识别，不把这类结果粘贴到光标处。

成功标准：

- 桌宠用 `voicetype://` 发起、结束、取消一次听写，VoiceType 用 `pet://transcript` 回传文字或失败原因。
- VoiceType 自己的快捷键听写行为不变。
- 整个过程不抢焦点、不动剪贴板。

## 2. 协议

| 方向 | URL | 含义 |
|---|---|---|
| 桌宠 → VoiceType | `voicetype://dictate?session=<id>&callback=pet%3A%2F%2Ftranscript` | 开始录音 |
| 桌宠 → VoiceType | `voicetype://stop?session=<id>` | 结束录音并识别 |
| 桌宠 → VoiceType | `voicetype://cancel?session=<id>` | 丢弃这次录音，不回传 |
| VoiceType → 桌宠 | `pet://transcript?session=<id>&text=<文字>` | 识别成功 |
| VoiceType → 桌宠 | `pet://transcript?session=<id>&error=<原因>` | 没有文字可给 |

- session 由桌宠生成，1–64 个字母、数字或连字符。
- 原因：`empty`（没说话或太短）、`mic_denied`、`not_ready`（模型没装或云端没填密钥）、`busy`、`failed`。
- 文字里除字母、数字和 `-._~` 以外的字节全部百分号编码。
- 文字全部放在 URL 里，不写临时文件。实测 135 KB 的 URL 也能完整送达，5 分钟听写约 14 KB。

## 3. 实现

- **注册 scheme：** `project.yml` 的 `info.properties` 加 `CFBundleURLTypes`。
- **接收 URL：** `AppDelegate` 在 `applicationWillFinishLaunching` 里接管 GetURL 事件。
  - 不用 SwiftUI 的 `onOpenURL`：菜单栏面板的视图只在面板打开时存在。
  - 不用默认处理：它会顺带打开一个空的「会议转写」窗口。
- **纯逻辑：** `PetBridge.swift`。请求解析、请求该做什么、回传 URL 拼接都是纯函数。
- **输出去向：** `DictationController` 的每次听写有一个去向。
  - `cursor`：现状。
  - `pet(session, callback)`：回传，不写剪贴板、不模拟 ⌘V、不引导辅助功能授权。
- **谁结束都回传：** 桌宠发起的录音，被 `stop`、被自己的快捷键、被 300 秒上限结束，结果都回传。
- **启动期间的请求：** 录音启动要等麦克风授权。这期间到达的 `stop` 或 `cancel` 先记下，启动完成后立刻执行。
- **正忙：** 正在录音、识别、润色，或会议录音进行中时，新的 `dictate` 直接回传 `busy`，不打断正在进行的事。
- **回传不抢焦点：** `NSWorkspace.OpenConfiguration.activates = false`。

## 4. 安全与隐私

- 回调只接受 `pet://transcript`。否则任何网页或 App 都能让 VoiceType 录音，并把文字发到任意地址。
- 录音期间 HUD 照常显示，系统的麦克风指示也在。
- 日志里不写识别到的文字。
- 这类听写照常进历史记录，来源为 `pet`。

## 5. 测试

- `PetBridgeTests`：请求解析、回调白名单、回传 URL 编码与往返、五种失败原因、长文本、请求在各状态下该做什么。
- 录音、URL 往返、焦点行为靠手工验收，清单在桌宠仓库的 `docs/superpowers/notes/pending-acceptance.md`。

## 6. 不做

- Windows 版的联动。
- 取消已经进入识别阶段的听写（桌宠那边会丢弃这次结果）。
