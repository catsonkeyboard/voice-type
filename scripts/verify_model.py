#!/usr/bin/env python3
"""用 sherpa-onnx python 包验证导出模型可正常识别（与 Swift 侧同一运行时）。

用法:
    uv pip install --python <venv>/bin/python sherpa-onnx soundfile
    <venv>/bin/python scripts/verify_model.py
"""
from pathlib import Path

import sherpa_onnx
import soundfile as sf

MODELS = Path.home() / "Library/Application Support/VoiceType/models"
WAV = (
    Path.home()
    / ".cache/modelscope/hub/models/iic"
    / "speech_seaco_paraformer_large_asr_nat-zh-cn-16k-common-vocab8404-pytorch"
    / "asr_example_hotword.wav"
)

recognizer = sherpa_onnx.OfflineRecognizer.from_sense_voice(
    model=str(MODELS / "model.int8.onnx"),
    tokens=str(MODELS / "tokens.txt"),
    use_itn=True,
)
samples, rate = sf.read(str(WAV), dtype="float32")
if samples.ndim > 1:
    samples = samples.mean(axis=1)
stream = recognizer.create_stream()
stream.accept_waveform(rate, samples)
recognizer.decode_stream(stream)
text = stream.result.text
print("识别结果:", text)
cjk = sum(1 for c in text if "一" <= c <= "鿿")
assert cjk >= 4, f"中文字符过少: {text!r}"
print("OK")
