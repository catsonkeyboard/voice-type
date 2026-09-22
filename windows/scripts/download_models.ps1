# 下载本地识别模型（int8）到 %APPDATA%\VoiceType\models
# 用法: powershell -ExecutionPolicy Bypass -File scripts\download_models.ps1 [funasr-nano|qwen3|all]
#   funasr-nano  Fun-ASR-Nano-2512（默认，约 1GB）中英混杂/方言最强
#   qwen3        Qwen3-ASR-0.6B（约 950MB）30 语种 + 22 中文方言
# SenseVoiceSmall 请用 scripts\export_sensevoice.ps1。
param([string]$Target = 'funasr-nano')
$ErrorActionPreference = 'Stop'

$Dest = Join-Path $env:APPDATA 'VoiceType\models'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

if ($Target -notin @('funasr-nano', 'qwen3', 'all')) {
    Write-Error "未知目标: $Target（可选 funasr-nano | qwen3 | all）"
}

function Fetch([string]$Name, [string]$OutDir) {
    $ms = "https://modelscope.cn/models/csukuangfj/asr-models/resolve/master/$Name"
    $gh = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$Name"
    $tmp = Join-Path $env:TEMP $Name
    Write-Host "下载 $Name …"
    try {
        Invoke-WebRequest -Uri $ms -OutFile $tmp -UseBasicParsing
    } catch {
        Write-Host "ModelScope 失败，回退 GitHub …"
        Invoke-WebRequest -Uri $gh -OutFile $tmp -UseBasicParsing
    }
    $extract = Join-Path $env:TEMP 'voicetype-model-extract'
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    New-Item -ItemType Directory -Force -Path $extract | Out-Null
    & "$env:windir\System32\tar.exe" -xjf $tmp -C $extract
    $inner = Get-ChildItem -Directory $extract | Select-Object -First 1
    $final = Join-Path $Dest $OutDir
    if (Test-Path $final) { Remove-Item -Recurse -Force $final }
    Move-Item $inner.FullName $final
    Remove-Item -Recurse -Force $extract
    Remove-Item $tmp
    Write-Host "OK $OutDir 安装完成"
}

if ($Target -in @('funasr-nano', 'all')) {
    if (-not (Test-Path (Join-Path $Dest 'funasr-nano\llm.int8.onnx'))) {
        Fetch 'sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2' 'funasr-nano'
    } else { Write-Host "funasr-nano 已安装" }
}
if ($Target -in @('qwen3', 'all')) {
    if (-not (Test-Path (Join-Path $Dest 'qwen3-asr\decoder.int8.onnx'))) {
        Fetch 'sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2' 'qwen3-asr'
    } else { Write-Host "qwen3-asr 已安装" }
}

Get-ChildItem $Dest | Where-Object { $_.Name -match 'funasr|qwen3|model\.int8|tokens' } |
    ForEach-Object { Write-Host ("{0,-16} {1,10:N1} MB" -f $_.Name, ($_.Length / 1MB)) }
