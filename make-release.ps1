<#
.SYNOPSIS
Packs zk-direct and the bundled game (and, for Windows, the engine) for a GitHub release:
  dist\zk-direct-<game>-windows.zip      zk-direct.cmd, the engine and the game
  dist\zk-direct-<game>-linux.tar.gz     zk-direct.sh and the game; Linux players use the engine Zero-K.exe downloaded

Run bundle\make-bundle.ps1 first if the bundle is out of date. Each archive has one top-level zk-direct\ folder:
players extract it anywhere and double-click zk-direct.cmd, or run ./zk-direct.sh. The Linux one is a tarball
because zips made on Windows can't mark zk-direct.sh executable.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$bundle = Get-Content (Join-Path $PSScriptRoot 'bundle\bundle.json') -Raw | ConvertFrom-Json
$common = 'zk-direct.ps1', 'README.md', 'bundle\bundle.json', "bundle\$($bundle.GameArchive)"
$windowsFiles = @('zk-direct.cmd') + $common + "bundle\$($bundle.EngineZip)"
$linuxFiles = @('zk-direct.sh') + $common
foreach ($f in $windowsFiles + $linuxFiles | Select-Object -Unique) { if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { throw "Missing $f." } }

$dist = Join-Path $PSScriptRoot 'dist'
[void](New-Item $dist -ItemType Directory -Force)
$base = Join-Path $dist ("zk-direct-" + ($bundle.Game.ToLower() -replace '[^a-z0-9.]+', '-'))

function Write-Done([string]$path) { Write-Host ("Wrote {0} ({1:N0} MB)" -f $path, ((Get-Item $path).Length / 1MB)) -ForegroundColor Green }

$out = "$base-windows.zip"
if (Test-Path $out) { Remove-Item $out }
$zip = [IO.Compression.ZipFile]::Open($out, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $windowsFiles) {
        # the bundle archives are already compressed; storing them is much faster and barely bigger
        $level = if ($f -match '\.(zip|sdz)$') { 'NoCompression' } else { 'Optimal' }
        Write-Host "Adding $f..."
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $PSScriptRoot $f), 'zk-direct/' + ($f -replace '\\', '/'), $level)
    }
} finally { $zip.Dispose() }
Write-Done $out

# A ustar header plus the file's bytes, padded to 512-byte blocks.
function Write-TarEntry($stream, [string]$name, [string]$path, [int]$mode) {
    $file = Get-Item $path
    $header = New-Object byte[] 512
    $put = { param([string]$text, [int]$offset) $b = [Text.Encoding]::ASCII.GetBytes($text); [Array]::Copy($b, 0, $header, $offset, $b.Length) }
    $octal = { param([long]$value, [int]$digits) [Convert]::ToString($value, 8).PadLeft($digits, '0') }
    & $put $name 0
    & $put (& $octal $mode 7) 100
    & $put (& $octal 0 7) 108                # uid
    & $put (& $octal 0 7) 116                # gid
    & $put (& $octal $file.Length 11) 124
    & $put (& $octal ([DateTimeOffset]$file.LastWriteTimeUtc).ToUnixTimeSeconds() 11) 136
    & $put '        ' 148                    # the checksum counts its own field as spaces
    & $put '0' 156                           # a regular file
    & $put "ustar`0" 257
    & $put '00' 263
    $sum = 0
    foreach ($b in $header) { $sum += $b }
    & $put ((& $octal $sum 6) + "`0 ") 148
    $stream.Write($header, 0, 512)
    $in = [IO.File]::OpenRead($file.FullName)
    try { $in.CopyTo($stream) } finally { $in.Dispose() }
    $pad = (512 - $file.Length % 512) % 512
    if ($pad) { $stream.Write((New-Object byte[] $pad), 0, $pad) }
}

$out = "$base-linux.tar.gz"
if (Test-Path $out) { Remove-Item $out }
$fs = [IO.File]::Create($out)
$gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionLevel]::Optimal)
try {
    foreach ($f in $linuxFiles) {
        Write-Host "Adding $f..."
        $mode = if ($f -like '*.sh') { 493 } else { 420 }  # rwxr-xr-x, rw-r--r--
        Write-TarEntry $gz ('zk-direct/' + ($f -replace '\\', '/')) (Join-Path $PSScriptRoot $f) $mode
    }
    $gz.Write((New-Object byte[] 1024), 0, 1024)  # two empty blocks end the archive
} finally { $gz.Dispose(); $fs.Dispose() }
Write-Done $out
