# VoiceType

macOS 菜单栏语音转写工具。全局快捷键（默认 ⌥Space）随时听写，识别结果直接输入到光标位置。基于 [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) + 阿里 FunASR [SenseVoiceSmall](https://modelscope.cn/models/iic/SenseVoiceSmall)（ONNX int8，本地推理，无网络依赖）。

## 功能

- 全局快捷键听写到光标（toggle：按一下开始，再按结束），SenseVoice 自带标点与数字归一化
- 状态栏面板：手动录音、转写历史（复制/删除）、音频文件拖拽转写（VAD 自动分段）
- 热词词表：拼音模糊匹配纠正专有名词
- 开机自启、快捷键自定义、录音悬浮 HUD

## 构建

前置：Xcode 15+、`brew install xcodegen`、`uv`

    ./scripts/export_model.sh   # 一次性：导出 SenseVoice ONNX int8 + 下载 VAD（模型装到 ~/Library/Application Support/VoiceType/models/）
    ./scripts/build.sh          # 产出 dist/VoiceType.app
    cp -R dist/VoiceType.app /Applications/

模型导出借用 voice-flow 项目的 Python venv（复用本地 modelscope 缓存的权重，零下载）。若本地无缓存，脚本会自动从 modelscope 下载。

## 首次运行授权

1. **麦克风**：首次录音时系统弹窗，允许即可
2. **辅助功能**：注入文本到光标需要。设置 → 权限 → 去授权，在系统设置中勾选 VoiceType

未授权辅助功能时自动降级：结果复制到剪贴板，手动 ⌘V 粘贴。

## 开发

    xcodegen                       # 生成 VoiceType.xcodeproj
    open VoiceType.xcodeproj       # Xcode 开发
    xcodebuild -project VoiceType.xcodeproj -scheme VoiceType \
      -destination 'platform=macOS' test   # 跑测试
