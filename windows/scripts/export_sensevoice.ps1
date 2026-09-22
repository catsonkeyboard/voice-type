# 安装 SenseVoiceSmall（约 230MB，轻量极速档）
# macOS 端的 export_model.sh 需要 FunASR/Python 环境；Windows 端统一改为
# 下载 sherpa-onnx 官方预编译包，取 model.int8.onnx + tokens.txt 放到 models 根。
# 用法: powershell -ExecutionPolicy Bypass -File scripts\export_sensevoice.ps1
$ErrorActionPreference = 'Stop'
$Dest = Join-Path $env:APPDATA 'VoiceType\models'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

if ((Test-Path (Join-Path $Dest 'model.int8.onnx')) -and
    (Test-Path (Join-Path $Dest 'tokens.txt'))) {
    Write-Host 'SenseVoice 已安装'
    exit 0
}

$Name = 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2'
$tmp = Join-Path $env:TEMP $Name
Write-Host "下载 $Name …"
$ms = "https://modelscope.cn/models/csukuangfj/asr-models/resolve/master/$Name"
$gh = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$Name"
try {
    Invoke-WebRequest -Uri $ms -OutFile $tmp -UseBasicParsing
} catch {
    Invoke-WebRequest -Uri $gh -OutFile $tmp -UseBasicParsing
}

$extract = Join-Path $env:TEMP 'voicetype-sense-extract'
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
New-Item -ItemType Directory -Force -Path $extract | Out-Null
& "$env:windir\System32\tar.exe" -xjf $tmp -C $extract
$inner = Get-ChildItem -Directory $extract | Select-Object -First 1
Copy-Item (Join-Path $inner.FullName 'model.int8.onnx') $Dest -Force
Copy-Item (Join-Path $inner.FullName 'tokens.txt') $Dest -Force
Remove-Item -Recurse -Force $extract, $tmp

# VAD 模型（sense-voice 包内不含）：从 sherpa-onnx releases 单独下载
if (-not (Test-Path (Join-Path $Dest 'silero_vad.onnx'))) {
    try {
        Invoke-WebRequest -Uri 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.tar.bz2' -OutFile (Join-Path $env:TEMP 'silero_vad.tar.bz2') -UseBasicParsing
        $vextract = Join-Path $env:TEMP 'voicetype-vad-extract'
        if (Test-Path $vextract) { Remove-Item -Recurse -Force $vextract }
        New-Item -ItemType Directory -Force -Path $vextract | Out-Null
        & "$env:windir\System32\tar.exe" -xjf (Join-Path $env:TEMP 'silero_vad.tar.bz2') -C $vextract
        $vad = Get-ChildItem -Recurse -Filter 'silero_vad.onnx' $vextract | Select-Object -First 1
        if ($vad) { Copy-Item $vad.FullName (Join-Path $Dest 'silero_vad.onnx') -Force }
        Remove-Item -Recurse -Force $vextract, (Join-Path $env:TEMP 'silero_vad.tar.bz2')
    } catch {
        Write-Host '警告：silero_vad.onnx 下载失败（需要 VAD 的场景请手动获取放入 models 目录）'
    }
}
Write-Host 'OK SenseVoiceSmall 安装完成'
