# 下载说话人分离模型（pyannote 分段 + 3D-Speaker 声纹，共约 35MB）
# 用法: powershell -ExecutionPolicy Bypass -File scripts\setup_diarization.ps1
$ErrorActionPreference = 'Stop'
$Dest = Join-Path $env:APPDATA 'VoiceType\models'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

if (-not (Test-Path (Join-Path $Dest 'segmentation.onnx'))) {
    $tmp = Join-Path $env:TEMP 'pyannote-seg.tar.bz2'
    Invoke-WebRequest -Uri 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2' -OutFile $tmp -UseBasicParsing
    $extract = Join-Path $env:TEMP 'voicetype-seg-extract'
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    & "$env:windir\System32\tar.exe" -xjf $tmp -C $extract
    Copy-Item (Join-Path $extract 'sherpa-onnx-pyannote-segmentation-3-0\model.onnx') (Join-Path $Dest 'segmentation.onnx')
    Remove-Item -Recurse -Force $extract, $tmp
    Write-Host 'OK segmentation.onnx'
} else { Write-Host 'segmentation.onnx 已存在' }

if (-not (Test-Path (Join-Path $Dest 'speaker-embedding.onnx'))) {
    # 注意：官方 release tag 的 recongition 为历史遗留错拼，保持原样
    Invoke-WebRequest -Uri 'https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx' -OutFile (Join-Path $Dest 'speaker-embedding.onnx') -UseBasicParsing
    Write-Host 'OK speaker-embedding.onnx'
} else { Write-Host 'speaker-embedding.onnx 已存在' }
