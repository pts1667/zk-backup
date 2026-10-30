<#
.SYNOPSIS
Rebuilds the bundled engine and game from an existing Zero-K install.

.DESCRIPTION
Writes into this folder:
  engine-<version>-win64.zip   the engine folder, zipped
  <game>.sdz                   the rapid game package, repacked as a single archive the engine loads from games\
  bundle.json                  what zk-direct.ps1 reads to install them

  .\make-bundle.ps1 -ZkPath C:\Users\me\Downloads\zero-k-portable [-Engine 2026.07.04] [-Game zk:stable]
#>
param(
    [Parameter(Mandatory)][string]$ZkPath,
    [string]$Engine = '2026.07.04',
    [string]$Game = 'zk:stable'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$out = $PSScriptRoot

function Open-Gzip([string]$path) {
    New-Object IO.Compression.GZipStream([IO.File]::OpenRead($path), [IO.Compression.CompressionMode]::Decompress)
}

# Resolve the rapid tag to a name and package hash, e.g. zk:stable -> Zero-K v1.14.10.3, ea34cf76...
$reader = New-Object IO.StreamReader(Open-Gzip (Join-Path $ZkPath 'rapid\repos.springrts.com\zk\versions.gz'))
$entry = $reader.ReadToEnd() -split "`n" | ForEach-Object { , ($_.Trim() -split ',') } |
    Where-Object { $_.Count -ge 4 -and ($_[0] -eq $Game -or $_[3] -eq $Game) } | Select-Object -First 1
$reader.Dispose()
if (-not $entry) { throw "'$Game' isn't in the install's rapid index." }
$gameName = $entry[3]
$sdp = Join-Path $ZkPath "packages\$($entry[1]).sdp"
if (-not (Test-Path $sdp)) { throw "$gameName isn't downloaded in '$ZkPath' (no $sdp)." }

$engineDir = Join-Path $ZkPath "engine\win64\$Engine"
if (-not (Test-Path (Join-Path $engineDir 'spring.exe'))) { throw "Engine $Engine isn't in '$ZkPath'." }

Get-ChildItem $out -File | Where-Object { $_.Extension -in '.zip', '.sdz' } | Remove-Item

$engineZip = "engine-$Engine-win64.zip"
Write-Host "Zipping engine $Engine..."
[IO.Compression.ZipFile]::CreateFromDirectory($engineDir, (Join-Path $out $engineZip), [IO.Compression.CompressionLevel]::Optimal, $false)

# .sdp is a gzipped list of [1B name length][name][16B md5][4B crc32][4B size];
# each file's content is in pool\<md5[0:2]>\<md5[2:]>.gz
$gameArchive = ($gameName.ToLower() -replace '[^a-z0-9.]+', '-') + '.sdz'
Write-Host "Packing $gameName into $gameArchive..."
$ms = New-Object IO.MemoryStream
$gz = Open-Gzip $sdp
$gz.CopyTo($ms)
$gz.Dispose()
$b = $ms.ToArray()
$zip = [IO.Compression.ZipFile]::Open((Join-Path $out $gameArchive), [IO.Compression.ZipArchiveMode]::Create)
try {
    $i = 0
    while ($i -lt $b.Length) {
        $name = [Text.Encoding]::UTF8.GetString($b, $i + 1, $b[$i])
        $i += 1 + $b[$i]
        $md5 = -join ($b[$i..($i + 15)] | ForEach-Object { $_.ToString('x2') })
        $i += 24
        $src = Open-Gzip (Join-Path $ZkPath "pool\$($md5.Substring(0, 2))\$($md5.Substring(2)).gz")
        $dst = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal).Open()
        try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() }
    }
} finally { $zip.Dispose() }

[ordered]@{ Engine = $Engine; EngineZip = $engineZip; Game = $gameName; GameArchive = $gameArchive } |
    ConvertTo-Json | Set-Content (Join-Path $out 'bundle.json') -Encoding ASCII
Get-ChildItem $out -File | Format-Table Name, @{ n = 'MB'; e = { [Math]::Round($_.Length / 1MB, 1) } } -AutoSize
