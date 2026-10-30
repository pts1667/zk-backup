<#
.SYNOPSIS
Packs zk-direct and the bundled engine and game into dist\zk-direct-<game>.zip for a GitHub release.

Run bundle\make-bundle.ps1 first if the bundle is out of date. The zip has one top-level zk-direct\
folder: players extract it anywhere and double-click zk-direct.cmd.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$bundle = Get-Content (Join-Path $PSScriptRoot 'bundle\bundle.json') -Raw | ConvertFrom-Json
$files = 'zk-direct.cmd', 'zk-direct.ps1', 'README.md', 'bundle\bundle.json', "bundle\$($bundle.EngineZip)", "bundle\$($bundle.GameArchive)"
foreach ($f in $files) { if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { throw "Missing $f." } }

$dist = Join-Path $PSScriptRoot 'dist'
[void](New-Item $dist -ItemType Directory -Force)
$out = Join-Path $dist ("zk-direct-" + ($bundle.Game.ToLower() -replace '[^a-z0-9.]+', '-') + '.zip')
if (Test-Path $out) { Remove-Item $out }

$zip = [IO.Compression.ZipFile]::Open($out, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        # the bundle archives are already compressed; storing them is much faster and barely bigger
        $level = if ($f -match '\.(zip|sdz)$') { 'NoCompression' } else { 'Optimal' }
        Write-Host "Adding $f..."
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $PSScriptRoot $f), 'zk-direct/' + ($f -replace '\\', '/'), $level)
    }
} finally { $zip.Dispose() }
Write-Host ("Wrote {0} ({1:N0} MB)" -f $out, ((Get-Item $out).Length / 1MB)) -ForegroundColor Green
