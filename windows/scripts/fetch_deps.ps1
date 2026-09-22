# 下载 sherpa-onnx 预编译 win-x64 DLL（含 onnxruntime）与 C 头文件
# 版本与 macOS 端一致：v1.13.3 + onnxruntime 1.24.4
# 用法: powershell -ExecutionPolicy Bypass -File scripts\fetch_deps.ps1
$ErrorActionPreference = 'Stop'
$Ver = 'v1.13.3'
$Ort = '1.24.4'
$Root = Split-Path $PSScriptRoot -Parent
$NativeDir = Join-Path $Root 'src\VoiceType\runtimes\win-x64\native'
$IncludeDir = Join-Path $Root 'src\VoiceType\Interop\SherpaOnnx\include'

if (Test-Path (Join-Path $NativeDir 'sherpa-onnx-c-api.dll')) {
    Write-Host "sherpa-onnx DLL 已存在，跳过（删除该目录可强制重新下载）"
    exit 0
}

# 资产名存在多种历史命名，逐个尝试；失败再走 GitHub API 兜底匹配
# v1.13.3 实测：win-x64 包名为 sherpa-onnx-<ver>-win-x64.tar.bz2（内含 lib/*.dll）
$Candidates = @(
    "sherpa-onnx-$Ver-win-x64",
    "sherpa-onnx-$Ver-onnxruntime-$Ort-win-x64-shared",
    "sherpa-onnx-$Ver-win-x64-shared"
)
$Assets = $null
foreach ($name in $Candidates) {
    foreach ($ext in @('tar.bz2', '7z')) {
        $url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/$Ver/$name.$ext"
        try {
            Invoke-WebRequest -Uri $url -OutFile "$env:TEMP\$name.$ext" -UseBasicParsing
            $Assets = "$env:TEMP\$name.$ext"
            break
        } catch {
            Write-Host "试过 $name.$ext（不可用）"
        }
    }
    if ($Assets) { break }
}

if (-not $Assets) {
    Write-Host "固定名未命中，通过 GitHub API 查找 win-x64 shared 资产…"
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/$Ver" -UseBasicParsing
    $asset = $rel.assets | Where-Object { $_.name -like '*win-x64*shared*' } | Select-Object -First 1
    if (-not $asset) { throw "release $Ver 中未找到 win-x64 shared 资产，请到 https://github.com/k2-fsa/sherpa-onnx/releases 手动下载" }
    $Assets = "$env:TEMP\$($asset.name)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $Assets -UseBasicParsing
}

Write-Host "下载完成：$Assets，解包…"
$Tmp = "$env:TEMP\sherpa-onnx-extract"
if (Test-Path $Tmp) { Remove-Item -Recurse -Force $Tmp }
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

if ($Assets -like '*.7z') {
    # 优先用系统 7z（Win11 24H2+ 自带），否则要求安装 7-Zip
    $sevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "$env:windir\System32\7z.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sevenZip) { throw "需要 7-Zip 解包 .7z 资产，请安装 7-Zip 或手动解压 $Assets" }
    & $sevenZip x -y "-o$Tmp" $Assets | Out-Null
} else {
    & "$env:windir\System32\tar.exe" -xjf "$Assets" -C $Tmp
}

New-Item -ItemType Directory -Force -Path $NativeDir | Out-Null
New-Item -ItemType Directory -Force -Path $IncludeDir | Out-Null

# 展开后的目录名不确定（可能带 onnxruntime 版本），定位包含 dll 的那一层
$DllDir = Get-ChildItem -Recurse -Filter 'sherpa-onnx-c-api.dll' -Path $Tmp |
    Select-Object -First 1
if (-not $DllDir) { throw "包内未找到 sherpa-onnx-c-api.dll" }
$DllDir = $DllDir.DirectoryName
Copy-Item (Join-Path $DllDir '*.dll') $NativeDir -Force

# 头文件（结构体布局校对依据）
$Header = Get-ChildItem -Recurse -Filter 'c-api.h' -Path $Tmp | Select-Object -First 1
if ($Header) {
    $Dest = Join-Path $IncludeDir 'sherpa-onnx\c-api'
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item $Header.FullName (Join-Path $Dest 'c-api.h') -Force
}

Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
Write-Host "✓ 依赖就位：$NativeDir"
Get-ChildItem $NativeDir | ForEach-Object { Write-Host "  $($_.Name)" }
