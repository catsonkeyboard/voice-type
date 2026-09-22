# 构建 VoiceType（Release，win-x64）
# 用法: powershell -ExecutionPolicy Bypass -File scripts\build.ps1 [-Configuration Debug]
param([string]$Configuration = 'Release')
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent

# sherpa-onnx 原生 DLL 默认经 NuGet 包 org.k2fsa.sherpa.onnx.runtime.win-x64 分发；
# 仅在需要用 GitHub release 手动部署时运行 fetch_deps.ps1（内网无 NuGet 源的场景）
dotnet build (Join-Path $Root 'src\VoiceType.sln') -c $Configuration
if ($LASTEXITCODE -ne 0) { throw '构建失败' }
Write-Host ''
Write-Host "✓ 构建完成: src\VoiceType\bin\$Configuration\net10.0-windows\win-x64\VoiceType.exe"
