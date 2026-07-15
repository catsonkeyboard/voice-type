# VoiceType v4 设计文档：会议转写与说话人分离（纯本地）

- 日期：2026-07-15
- 状态：已获用户批准
- 前置：v1~v3 已交付

## 1. 目标

现场会议场景（多人共用本机麦克风）：录制或导入长音频 → 纯本地区分说话人 → 按说话人分段转写 → 独立窗口展示，支持改名/导出 Markdown/LLM 生成纪要。

成功标准：2~4 人轮流发言的清晰录音，分段与归属基本正确；1 小时录音处理时间 ≤ 5 分钟（Apple Silicon）；全程本地，录音与转写不出机器（纪要走用户配置的 LLM 通道，本地 Ollama 默认）。

## 2. 技术路线（已验证可行性）

- **分离**：sherpa-onnx `OfflineSpeakerDiarization`（vendored Swift 绑定与 dylib C 符号已确认在库）：pyannote segmentation-3.0（约 6MB）切说话区间 + 3D-Speaker CAM++ 中文声纹（约 28MB）嵌入 + FastClustering 聚类（`numClusters=-1` 自动估计人数，或设置指定 2~8；阈值默认 0.5）
- **转写**：现有 `AsrService`（SenseVoice）逐段识别
- **纪要**：`PolishService` 新增通用 `complete(system:user:) async -> String?`，润色与纪要共用 LLM 通道与降级逻辑
- 模型放现有 models 目录（`segmentation.onnx`、`speaker-embedding.onnx`），`scripts/setup_diarization.sh` 自动下载（约 35MB，属小依赖）

## 3. 组件与数据流

```
【会议录音】面板「开始会议录音」→ MeetingRecorder（AudioRecorder.onChunk → 实时写 wav 落盘，上限 3h，
            期间禁用快捷键听写）→ 停止 → MeetingProcessor
【文件导入】面板文件区「区分说话人」→ MeetingProcessor
MeetingProcessor: decode16k → DiarizationService.diarize → 相邻同人段合并（间隔<1s）
               → 逐段 AsrService.transcribe（进度回调）→ MeetingTranscript(JSON 落盘)
               → 打开 MeetingResultWindow
```

- `DiarizationService`: `diarize(samples:[Float], numSpeakers: Int?) throws -> [SpeakerSegment]`；`SpeakerSegment{speaker:Int, start:Double, end:Double}`；模型懒加载常驻
- `MeetingTranscript`: `{createdAt, duration, audioFile, segments:[{speaker, start, end, text}], speakerNames:[Int:String]}`，Codable JSON 与音频同名存 `~/Library/Application Support/VoiceType/meetings/`
- `MeetingResultWindow`（SwiftUI WindowGroup + openWindow）：分段列表（说话人色块+时间戳+文本）、说话人改名（全文生效并回写 JSON）、复制全文、导出 Markdown（NSSavePanel）、「生成纪要」按钮（输出主题/要点/决议/待办，展示于窗口内可复制）
- `AppState` 新增 `meeting: MeetingPhase`（idle/recording(elapsed)/processing(progress,stage)/failed(msg)）
- 面板新增「会议」区；文件区加「区分说话人」按钮；录音中 DictationController.toggle 直接 HUD 提示不可用

## 4. 错误处理

| 场景 | 行为 |
|---|---|
| 分离模型缺失 | 会议功能按钮置灰 + 提示跑 `scripts/setup_diarization.sh`；设置识别页显示状态 |
| 分离失败 | 降级纯转写（整段 VAD 转写，无说话人标签）+ 窗口顶部提示 |
| 录音中 App 退出 | wav 已落盘于 meetings 目录，可从文件入口重新处理 |
| 纪要 LLM 失败 | 按钮下方红字提示，分段稿不受影响 |
| 本地 ASR 模型缺失 | 会议功能不可用（与听写同门槛） |

## 5. 测试

- 单测：段合并算法（间隔阈值/不同说话人不合并/排序）、Markdown 生成（含改名映射）、MeetingTranscript JSON 往返、纪要 prompt 构造
- 集成（分离模型缺失时 XCTSkip）：拼接本地两段不同说话人示例音频（modelscope 缓存现成 wav），断言分离出 ≥2 说话人、分段转写非空
- 人工验收：真实会议录音全流程 + 改名 + 导出 + 纪要

## 6. 范围外（YAGNI）

会议库/搜索、实时逐句上屏、声纹注册自动认人、系统音频捕获（线上会议）、重叠语音分离。
