# Generates win/rudy.ico from shared/spritesheet.png (frame 4 of 6).
#
# The icon is one of the walk poses, cropped to its alpha bounds and
# letterboxed into a square, rendered at every size Windows asks for and
# stored as PNG entries (supported by Vista and later; Windows 10/11 only
# here, so no BMP fallback is needed).
#
# 256 px is deliberately left out: it is a third of the whole .ico and Rudy
# only ever shows up in the tray at 16-32 px. 128 is plenty for Explorer.
#
#   powershell -ExecutionPolicy Bypass -File win\make-icon.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root  = Split-Path -Parent $PSScriptRoot
$sheetPath = Join-Path $root 'shared\spritesheet.png'
$out   = Join-Path $PSScriptRoot 'rudy.ico'
$sizes = @(16, 24, 32, 48, 64, 128)
$cell  = 128
$frameIndex = 3

$PArgb = [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb

$sheet = [System.Drawing.Bitmap]::FromFile($sheetPath)

# --- pick the pose and find its ink ------------------------------------------
$pose = [System.Drawing.Bitmap]::new($cell, $cell, $PArgb)
$g = [System.Drawing.Graphics]::FromImage($pose)
$g.DrawImage($sheet, [System.Drawing.Rectangle]::new(0, 0, $cell, $cell),
                     [System.Drawing.Rectangle]::new($frameIndex * $cell, 0, $cell, $cell),
                     [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()

$x0 = $cell; $y0 = $cell; $x1 = -1; $y1 = -1
for ($y = 0; $y -lt $cell; $y++) {
    for ($x = 0; $x -lt $cell; $x++) {
        if ($pose.GetPixel($x, $y).A -gt 24) {
            if ($x -lt $x0) { $x0 = $x }
            if ($x -gt $x1) { $x1 = $x }
            if ($y -lt $y0) { $y0 = $y }
            if ($y -gt $y1) { $y1 = $y }
        }
    }
}
if ($x1 -lt 0) { throw 'Frame appears to be empty.' }

$inkW = $x1 - $x0 + 1
$inkH = $y1 - $y0 + 1
$side  = [Math]::Max($inkW, $inkH) * 1.10
$left  = ($x0 + $x1 + 1) / 2 - $side / 2
$top   = ($y0 + $y1 + 1) / 2 - $side / 2

$enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
       Where-Object { $_.MimeType -eq 'image/png' }

$entries = @()
foreach ($s in $sizes) {
    $bmp = [System.Drawing.Bitmap]::new($s, $s, $PArgb)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.Clear([System.Drawing.Color]::Transparent)
    $gr.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gr.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $scale = $s / $side
    $dest = [System.Drawing.RectangleF]::new(
        [single](-$left * $scale), [single](-$top * $scale),
        [single]($cell * $scale), [single]($cell * $scale))
    $src = [System.Drawing.RectangleF]::new(0, 0, $cell, $cell)
    $gr.DrawImage($pose, $dest, $src, [System.Drawing.GraphicsUnit]::Pixel)
    $gr.Dispose()

    $ms = [System.IO.MemoryStream]::new()
    $bmp.Save($ms, $enc, $null)
    $bmp.Dispose()
    $entries += [pscustomobject]@{ Size = $s; Bytes = $ms.ToArray() }
    $ms.Dispose()
}
$pose.Dispose()
$sheet.Dispose()

# --- assemble the .ico -------------------------------------------------------
$fs = [System.IO.File]::Create($out)
$bw = [System.IO.BinaryWriter]::new($fs)
$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$entries.Count)

$offset = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
    $bw.Write([byte]$dim)
    $bw.Write([byte]$dim)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$e.Bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $e.Bytes.Length
}
foreach ($e in $entries) { $bw.Write($e.Bytes) }
$bw.Flush()
$bw.Dispose()
$fs.Dispose()

$f = Get-Item $out
'{0}  ({1:N0} bytes, {2} sizes)' -f $f.FullName, $f.Length, $entries.Count
