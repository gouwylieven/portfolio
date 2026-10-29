# Builds dist/Rudy.exe with the in-box .NET Framework C# compiler.
#
# No SDK, no NuGet, no project file, no runtime to install: csc.exe has
# shipped with Windows since .NET Framework 4.x, and 4.8 is part of
# Windows 10 and 11. The sprite sheet is embedded, so the result is a
# single self-contained executable of roughly 40 KB.
#
#   powershell -ExecutionPolicy Bypass -File win\build.ps1

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'
$out  = Join-Path $dist 'Rudy.exe'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path $csc)) {
    throw 'csc.exe not found. .NET Framework 4.x is required (in-box on Windows 10/11).'
}

New-Item -ItemType Directory -Force -Path $dist | Out-Null

$args = @(
    '/nologo'
    '/target:winexe'
    '/optimize+'
    '/platform:anycpu'
    '/r:System.dll'
    '/r:System.Drawing.dll'
    '/r:System.Windows.Forms.dll'
    "/win32icon:$PSScriptRoot\rudy.ico"
    "/win32manifest:$PSScriptRoot\app.manifest"
    "/resource:$root\shared\spritesheet.png,Rudy.sheet.png"
    "/resource:$PSScriptRoot\rudy.ico,Rudy.icon.ico"
    "/out:$out"
    "$PSScriptRoot\Rudy.cs"
)

& $csc $args
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

$f = Get-Item $out
'{0}  ({1:N0} bytes)' -f $f.FullName, $f.Length
