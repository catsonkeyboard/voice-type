# 生成托盘图标（Assets/app.ico 空闲态 / app-rec.ico 录音态）
# 用 GDI+ 画一个圆角方块 + 麦克风造型，单尺寸 32x32 ICO。一次性脚本，产物已提交。
# 用法: powershell -ExecutionPolicy Bypass -File scripts\make_icon.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path $PSScriptRoot -Parent
$outDir = Join-Path $root 'src\VoiceType\Assets'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function New-Icon([int]$size, [string]$bgHex, [string]$fgHex, [string]$outPath) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $bg = [System.Drawing.ColorTranslator]::FromHtml($bgHex)
    $fg = [System.Drawing.ColorTranslator]::FromHtml($fgHex)
    $w = $size - 1

    # 圆角背景
    $r = [int]($size * 0.26)
    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $w)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $x2 = $w - $d
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($x2, 0, $d, $d, 270, 90)
    $path.AddArc($x2, $x2, $d, $d, 0, 90)
    $path.AddArc(0, $x2, $d, $d, 90, 90)
    $path.CloseFigure()
    $bgBrush = New-Object System.Drawing.SolidBrush($bg)
    $g.FillPath($bgBrush, $path)

    # 麦克风：胶囊体 + 支架
    $fgBrush = New-Object System.Drawing.SolidBrush($fg)
    $penWidth = [Math]::Max(2, [int]($size / 12))
    $pen = New-Object System.Drawing.Pen($fg, $penWidth)
    $micW = [int]($size * 0.26)
    $micH = [int]($size * 0.40)
    $micX = [int](($size - $micW) / 2)
    $micY = [int]($size * 0.18)
    $micRect = New-Object System.Drawing.Rectangle($micX, $micY, $micW, $micH)
    $g.FillEllipse($fgBrush, $micRect)
    $arcX = [int]($size * 0.22)
    $arcY = [int]($size * 0.30)
    $arcW = [int]($size * 0.56)
    $arcH = [int]($size * 0.50)
    $arcRect = New-Object System.Drawing.Rectangle($arcX, $arcY, $arcW, $arcH)
    $g.DrawArc($pen, $arcRect, 20, 140)
    $mid = [int]($size / 2)
    $g.DrawLine($pen, $mid, [int]($size * 0.80), $mid, [int]($size * 0.90))
    $g.DrawLine($pen, [int]($size * 0.36), [int]($size * 0.90), [int]($size * 0.64), [int]($size * 0.90))

    $g.Dispose()

    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $fs = [System.IO.File]::Create($outPath)
    $icon.Save($fs)
    $fs.Close()
    $icon.Dispose()
    $bmp.Dispose()
    Write-Host "OK $outPath"
}

New-Icon 32 '#2F6FDB' '#FFFFFF' (Join-Path $outDir 'app.ico')
New-Icon 32 '#E5484D' '#FFFFFF' (Join-Path $outDir 'app-rec.ico')
