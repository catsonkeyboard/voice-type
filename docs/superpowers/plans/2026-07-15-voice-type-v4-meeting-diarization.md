# VoiceType v4 会议转写与说话人分离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 会议录音/文件 → 本地说话人分离 → 分段转写 → 结果窗口（改名/导出/纪要）。

**Architecture:** DiarizationService（sherpa-onnx 已 vendored 的 diarization 绑定）+ MeetingRecorder（chunk 落盘）+ MeetingProcessor（编排）+ MeetingResultWindow；纪要复用 PolishService 新增的通用 complete()。

**已核实事实：**
- Swift 绑定：`sherpaOnnxOfflineSpeakerDiarizationConfig(segmentation:embedding:clustering:minDurationOn:minDurationOff:)`、`sherpaOnnxFastClusteringConfig(numClusters:-1 自动, threshold: 0.5)`、`SherpaOnnxOfflineSpeakerDiarizationWrapper.process(samples:) -> [SegmentWrapper{start,end,speaker}]`（已按开始时间排序）
- 模型下载（sherpa-onnx releases，实施时校验 URL，注意官方 tag 拼写 `speaker-recongition-models` 是历史遗留错拼）：
  - `speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2` → 解出 `model.onnx` → 存为 `segmentation.onnx`
  - `speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx` → 存为 `speaker-embedding.onnx`
- 双人集成测试音频：拼接 `~/.cache/modelscope/.../speech_seaco_paraformer.../asr_example_hotword.wav`（男声）与 `~/.cache/modelscope/hub/models/iic/SenseVoiceSmall/example/` 下任一不同说话人 wav（实施时 `ls` 确认；若无则用 en 例音频）
- 通用命令同 v1~v3；新文件后先 `xcodegen`

**文件结构：**

```
VoiceType/Services/DiarizationService.swift    # 分离封装 + SpeakerSegment + 段合并纯函数
VoiceType/Services/MeetingTranscript.swift     # Codable 模型 + Markdown 生成 + 存取
VoiceType/Services/MeetingRecorder.swift       # 长录音落盘
VoiceType/Services/MeetingProcessor.swift      # 编排（分离→合并→逐段转写→落盘）
VoiceType/Services/MinutesPrompt.swift         # 纪要 prompt 构造
VoiceType/UI/MeetingResultView.swift           # 结果窗口
VoiceTypeTests/DiarizationLogicTests.swift     # 合并/Markdown/JSON/prompt 单测
VoiceTypeTests/DiarizationIntegrationTests.swift  # 双人音频集成（模型缺失跳过）
scripts/setup_diarization.sh
（修改）AsrService(ModelPaths 扩展) / PolishService(complete) / AppState / DictationController(录音互斥)
        / PanelView(会议区+文件区按钮) / VoiceTypeApp(WindowGroup) / SettingsView(模型状态) / README
```

### Task 1: 模型下载脚本 + ModelPaths 扩展
- [ ] `scripts/setup_diarization.sh`：下载两模型入 models 目录（存在即跳过），`ls -lh` 收尾；执行验证
- [ ] `ModelPaths` 增 `segmentationModel`/`speakerEmbeddingModel`/`diarizationPresent`
- [ ] Commit `feat(v4): 说话人分离模型下载与路径`

### Task 2: DiarizationService + 段合并（TDD）
- [ ] `SpeakerSegment{speaker:Int, start:Double, end:Double, text:String=""}` (Codable/Equatable)
- [ ] 纯函数 `mergeAdjacent(_ segs:[SpeakerSegment], maxGap: Double = 1.0) -> [SpeakerSegment]`：同 speaker 且 gap≤maxGap 合并；单测：合并/不同人不并/大间隔不并/空数组
- [ ] `DiarizationService.diarize(samples:[Float], numSpeakers: Int?) throws -> [SpeakerSegment]`：懒加载 wrapper（numClusters = numSpeakers ?? -1，threshold 0.5），`process` 后映射；模型缺失 throw `DiarizationError.modelMissing`
- [ ] 单测跑通 + Commit `feat(v4): 说话人分离服务与段合并 (TDD)`

### Task 3: MeetingTranscript + Markdown（TDD）
- [ ] `MeetingTranscript{createdAt, duration, audioFile, segments, speakerNames:[Int:String]}`；`displayName(for:)`＝自定义名 ?? "说话人N+1"；`markdown()` 输出 `**张三 [mm:ss]** 文本` 行；`save(to:)/load(from:)` JSON
- [ ] 单测：markdown 含改名/时间戳格式、JSON 往返；Commit `feat(v4): 会议稿模型与 Markdown 导出 (TDD)`

### Task 4: MeetingRecorder + MeetingProcessor + PolishService.complete
- [ ] `MeetingRecorder`：`start() throws`（复用独立 AudioRecorder 实例，onChunk → AVAudioFile 增量写 `meetings/yyyyMMdd-HHmmss.wav`）、`stop() -> URL`、`elapsed`；上限 3h 自动停
- [ ] `MeetingProcessor.process(url:, numSpeakers:, onProgress:(String,Double)->Void) async throws -> MeetingTranscript`：decode→diarize→merge→逐段 slice samples 转写→落盘 JSON；分离 throw 时降级：整段 `transcribeFile` 塞进单说话人段并标记 `degraded`
- [ ] `PolishService` 增 `func complete(system: String, user: String) async -> String?`（与 polish 同请求路径、60s 超时、无长度校验）；`MinutesPrompt.system/user(transcript:)`
- [ ] 全量测试 + Commit `feat(v4): 会议录制与处理编排`

### Task 5: UI（AppState/面板/结果窗口/互斥/设置）
- [ ] `AppState.meeting: MeetingPhase{idle, recording(startedAt), processing(stage,progress), failed(String)}`
- [ ] `DictationController.toggle()` 会议录音中 → HUD"会议录音中，听写不可用"
- [ ] PanelView 「会议」区（开始/停止+时长+进度）；文件区加「区分说话人」按钮（`diarizationPresent` 才可用）
- [ ] `MeetingResultView` + `VoiceTypeApp` 加 `WindowGroup(id:"meeting", for: URL.self)`（传 transcript JSON 路径）：分段列表、改名弹窗（TextField，写回 JSON）、复制全文、导出 md（NSSavePanel）、生成纪要按钮（结果区展示+复制，失败红字）
- [ ] SettingsView 识别页加分离模型状态与脚本指引
- [ ] 全量测试 + Commit `feat(v4): 会议 UI（面板/结果窗口/纪要）`

### Task 6: 集成测试 + README + 交付
- [ ] `DiarizationIntegrationTests`：模型缺失 XCTSkip；拼接两个不同说话人 wav（各取 5s，中间插 0.5s 静音）→ diarize 断言 ≥2 说话人；MeetingProcessor 全链路断言各段 text 非空
- [ ] README 中英加会议功能段
- [ ] 全量测试 → `./scripts/install.sh` → Commit `feat(v4): 会议转写完成` → push
- [ ] 用户验收清单：跑 setup 脚本 → 面板录一段两人对话 → 查分段/改名/导出/纪要
