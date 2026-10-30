<#
.SYNOPSIS
Direct-IP Zero-K multiplayer without the Zero-K lobby server.

.DESCRIPTION
The host runs a tiny text lobby (TCP) where players gather, chat and pick teams.
When the host types /start, everyone's engine is launched with a generated script
and connects straight to the host's game (UDP, same port number).

  Window:  zk-direct.cmd                      (no arguments: join, or host with "Host a game...")
  Join:    zk-direct.cmd join 203.0.113.5 -Name Bob   (in the terminal)
  Host:    zk-direct.cmd host -Name Tom [-Map "TitanDuel 2.2"] [-Port 8452]   (in the terminal)
  Link:    zk-direct.cmd install   (once; then zkjoinbk://203.0.113.5:8452 links open the join window)

Players reach the host in one of two ways, and a lobby takes both at once:
  - Directly on -Port, over BOTH TCP and UDP. The host asks the router to forward it (UPnP; -NoUpnp to
    skip) and removes the forward when the lobby closes. Otherwise forward it by hand, or have everyone
    join the same VPN (Tailscale, ZeroTier, Radmin VPN) and use that IP.
  - Through a Cloudflare quick tunnel, when cloudflared.exe is found (-Cloudflared <path>; -NoTunnel to
    skip). Works with no open port at all; players join with the https://....trycloudflare.com address.

The Zero-K folder (the one containing engine\) is found from, in order: -ZkDir (alias -ZkPath),
the ZK_DIR environment variable, the last folder used, this script's folder, Steam libraries,
common install places; the window asks to confirm it once, the terminal only asks if none is found.
The choice and your name are remembered in %LOCALAPPDATA%\zk-direct. Your name defaults to
the one you log in to Zero-K with.
#>
param(
    [Parameter(Position = 0)][string]$Mode,
    [Parameter(Position = 1)][string]$Address,
    [string]$Name,
    [int]$Port = 8452,
    [string]$Map = 'TitanDuel 2.2',
    [string]$Game = 'zk:stable',
    [string]$Engine,
    [Alias('ZkPath')][string]$ZkDir,
    [switch]$NoUpnp,
    [switch]$NoTunnel,
    [string]$Cloudflared
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
$configDir = Join-Path $env:LOCALAPPDATA 'zk-direct'
$nameFile = Join-Path $configDir 'name.txt'
$zkDirFile = Join-Path $configDir 'zkdir.txt'
$addressFile = Join-Path $configDir 'address.txt'
$cloudflaredFile = Join-Path $configDir 'cloudflared.txt'
$hostUpnpFile = Join-Path $configDir 'host-upnp.txt'      # the window's host options: on or off
$hostTunnelFile = Join-Path $configDir 'host-tunnel.txt'
$namePattern = '^[A-Za-z0-9_\-\[\]]{1,30}$'
$ui = $null  # the join window's controls, when it's open
$bundleDir = Join-Path $scriptDir 'bundle'
$aiDifficulties = 'Beginner', 'Novice', 'Easy', 'Normal', 'Hard', 'Brutal'

# ---------------------------------------------------------------- content

# [IO.Path]::Combine rather than Join-Path, which throws on a missing drive (e.g. an unplugged Steam library)
function Test-ZkDir([string]$dir) { $dir -and (Test-Path ([IO.Path]::Combine($dir, 'engine', 'win64'))) }

function Get-SteamZkDirs {
    $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if (-not $steam) { return }
    $libraries = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) { $libraries += [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } }
    $libraries | ForEach-Object { [IO.Path]::Combine($_, 'steamapps', 'common', 'Zero-K') }
}

function Get-SavedSetting([string]$file) {
    if (Test-Path $file) { (Get-Content $file -Raw).Trim() }
}

function Save-Setting([string]$file, [string]$value) {
    [void](New-Item $configDir -ItemType Directory -Force)
    [IO.File]::WriteAllText($file, $value, $utf8)
}

# Lazily, so later (slower) places are only searched when the earlier ones have nothing.
function Get-ZkDirCandidates {
    $ZkDir
    $env:ZK_DIR
    Get-SavedSetting $zkDirFile
    $scriptDir
    Split-Path $scriptDir
    Get-SteamZkDirs
    foreach ($root in ${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) { if ($root) { Join-Path $root 'Zero-K' } }
    # standalone installs are often unzipped somewhere like Downloads\zero-k-portable
    foreach ($parent in (Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'), 'C:\Games') {
        if ($parent -and (Test-Path $parent)) { Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName }
    }
}

function Get-DefaultZkDir {
    $found = Get-ZkDirCandidates | Where-Object { Test-ZkDir $_ } | Select-Object -First 1
    if ($found) { (Resolve-Path $found).Path }
}

function Find-ZkDir {
    if ($ZkDir -and -not (Test-ZkDir $ZkDir)) { throw "'$ZkDir' isn't a Zero-K folder (no engine\win64 inside)." }
    $found = Get-DefaultZkDir
    while (-not $found) {
        $answer = (Read-Host 'Path to your Zero-K folder (the one containing engine\)').Trim('" ')
        if (Test-ZkDir $answer) { $found = (Resolve-Path $answer).Path } else { Write-Host "No engine\win64 in '$answer'." -ForegroundColor Red }
    }
    Save-Setting $zkDirFile $found
    $found
}

# The name you log in to Zero-K with, from the lobby's saved settings (LuaMenu\Config\<lobby>_data.lua).
function Get-ZkLoginName([string]$dir) {
    if (-not (Test-ZkDir $dir)) { return }
    foreach ($file in Get-ChildItem ([IO.Path]::Combine($dir, 'LuaMenu', 'Config')) -Filter '*_data.lua' -ErrorAction SilentlyContinue) {
        $m = Select-String -LiteralPath $file.FullName -Pattern '^\s*userName = "(.+)",\s*$' | Select-Object -First 1
        if ($m -and $m.Matches[0].Groups[1].Value -match $namePattern) { return $m.Matches[0].Groups[1].Value }
    }
}

function Get-EngineDir([string]$version, [string]$dir = $ZkDir) {
    $root = Join-Path $dir 'engine\win64'
    if ($version) { return Join-Path $root $version }
    $dirs = Get-ChildItem $root -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'spring.exe') }
    ($dirs | Sort-Object { [version]($_.Name -replace '[^\d.].*$', '') } | Select-Object -Last 1).FullName
}

function Get-RapidEntries {
    $file = Join-Path $ZkDir 'rapid\repos.springrts.com\zk\versions.gz'
    if (-not (Test-Path $file)) { return }
    $fs = [IO.File]::OpenRead($file)
    try {
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
        $text = (New-Object IO.StreamReader($gz)).ReadToEnd()
    } finally { $fs.Dispose() }
    foreach ($line in $text -split "`n") {
        $f = $line.Trim() -split ','
        if ($f.Count -ge 4) { [pscustomobject]@{ Tag = $f[0]; Hash = $f[1]; Name = $f[3] } }
    }
}

# bundle\bundle.json, written by bundle\make-bundle.ps1: the engine and game shipped with this repo
function Get-Bundle {
    $file = Join-Path $bundleDir 'bundle.json'
    if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json }
}

function Get-BundleFile([string]$name) {
    $path = Join-Path $bundleDir $name
    if (-not (Test-Path $path)) { Write-Note "No bundle\$name; the zip on the repo's Releases page includes it."; return }
    $path
}

# Copies the bundled engine and game into the install when it doesn't have them.
function Install-Bundle {
    $bundle = Get-Bundle
    if (-not $bundle) { return }
    $engineDir = Join-Path $ZkDir "engine\win64\$($bundle.Engine)"
    if (-not (Test-Path (Join-Path $engineDir 'spring.exe'))) {
        $zip = Get-BundleFile $bundle.EngineZip
        if ($zip) {
            Write-Note "Installing bundled engine $($bundle.Engine)..."
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $engineDir)
        }
    }
    if (-not (Test-GameInstalled $bundle.Game)) {
        $archive = Get-BundleFile $bundle.GameArchive
        if ($archive) {
            Write-Note "Installing bundled $($bundle.Game) (this can take a minute)..."
            [void](New-Item (Join-Path $ZkDir 'games') -ItemType Directory -Force)
            Copy-Item $archive (Join-Path $ZkDir 'games')
        }
    }
}

# 'zk:stable' -> 'Zero-K v1.14.10.3'; full names pass through
function Resolve-GameName([string]$game) {
    $entry = Get-RapidEntries | Where-Object Tag -eq $game | Select-Object -First 1
    if ($entry) { return $entry.Name }
    $bundle = Get-Bundle
    if ($game -eq 'zk:stable' -and $bundle) { return $bundle.Game }  # install has no rapid index
    return $game
}

function Test-GameInstalled([string]$gameName) {
    $bundle = Get-Bundle
    if ($bundle -and $bundle.Game -eq $gameName -and (Test-Path (Join-Path $ZkDir "games\$($bundle.GameArchive)"))) { return $true }
    $entry = Get-RapidEntries | Where-Object Name -eq $gameName | Select-Object -First 1
    if (-not $entry) { return $false }
    Test-Path (Join-Path $ZkDir "packages\$($entry.Hash).sdp")
}

# Map name -> archive file, from the engine's archive cache; falls back to matching file names
# for maps the engine hasn't scanned yet.
function Find-MapArchive([string]$map) {
    $cache = Get-ChildItem (Join-Path $ZkDir 'cache') -Filter 'ArchiveCache*.lua' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($cache) {
        $file = $null; $dir = $null; $prev = ''
        foreach ($line in [IO.File]::ReadLines($cache.FullName)) {
            if ($line -match '^\s*path = "(.*)",$') {
                $dir = $Matches[1]
                if ($prev -match '^\s*name = "(.*)",$') { $file = $Matches[1] }
            } elseif ($file -and $line -match '^\s*name = "(.*)",$' -and $Matches[1] -eq $map) {
                $path = [IO.Path]::Combine($dir, $file)
                if (Test-Path $path) { return (Resolve-Path $path).Path }
            }
            $prev = $line
        }
    }
    $key = ($map.ToLower() -replace '[^a-z0-9]', '')
    Get-ChildItem (Join-Path $ZkDir 'maps') -File -ErrorAction SilentlyContinue |
        Where-Object { ($_.BaseName.ToLower() -replace '[^a-z0-9]', '') -eq $key } | Select-Object -First 1 | ForEach-Object FullName
}

function Test-MapInstalled([string]$map) { [bool](Find-MapArchive $map) }

function Invoke-Download([string]$kind, [string]$what) {
    Say "Downloading $kind '$what'..." Yellow
    if ($script:ui) { $script:ui.Status.Text = "Downloading $kind '$what'..."; $script:ui.Form.Refresh() }  # the window waits for it
    & (Join-Path $script:EngineDir 'pr-downloader.exe') --filesystem-writepath $ZkDir "--download-$kind" $what | Out-Host
    if ($LASTEXITCODE -ne 0) { Say "Couldn't download $kind '$what'. Get it manually or the game will fail to load." Red }
}

function Confirm-Content([string]$gameName, [string]$map) {
    if (-not (Test-GameInstalled $gameName)) { Invoke-Download 'game' $gameName }
    if (-not (Test-MapInstalled $map)) { Invoke-Download 'map' $map }
}

function Get-BotShortName([string]$difficulty) {
    $dirs = @((Join-Path $ZkDir 'AI\Skirmish'), (Join-Path $script:EngineDir 'AI\Skirmish') | Where-Object { Test-Path $_ })
    if (-not $dirs.Count) { return 'CircuitAI' }
    $match = Get-ChildItem $dirs -Directory | Where-Object Name -match "^\d*CircuitAI$difficulty\d*$" |
        Sort-Object { [long]('0' + ($_.Name -replace 'CircuitAI.*$', '')) } -Descending | Select-Object -First 1  # newest version prefix, like Chobby
    if ($match) { return $match.Name }
    return 'CircuitAI'
}

function Start-Spring([string]$scriptText) {
    $path = Join-Path $ZkDir "zk-direct-$Mode.txt"  # per role, so a local host+join test doesn't overwrite the host's script
    [IO.File]::WriteAllText($path, $scriptText, $utf8)
    Start-Process -PassThru -FilePath (Join-Path $script:EngineDir 'spring.exe') -WorkingDirectory $ZkDir `
        -ArgumentList '--write-dir', "`"$ZkDir`"", "`"$path`""
}

# ---------------------------------------------------------------- console

$script:inputBuf = ''

function Show-Prompt {
    $width = 80
    try { $width = [Console]::WindowWidth } catch {}
    [Console]::Write("`r" + (' ' * ($width - 1)) + "`r> " + $script:inputBuf)
}

function Say([string]$msg, [string]$color = 'Gray') {
    if ($script:ui) { Write-GuiLog $msg $color; return }
    $width = 80
    try { $width = [Console]::WindowWidth } catch {}
    [Console]::Write("`r" + (' ' * ($width - 1)) + "`r")
    Write-Host $msg -ForegroundColor $color
    Show-Prompt
}

# For setup messages, before there's a lobby prompt to keep at the bottom.
function Write-Note([string]$msg) {
    if ($script:ui) { Write-GuiLog $msg 'Yellow' } else { Write-Host $msg -ForegroundColor Yellow }
}

# Non-blocking line editor, so the lobby keeps polling sockets while you type.
function Read-InputLine {
    try { if (-not [Console]::KeyAvailable) { return $null } } catch { return $null }  # no console attached
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq 'Enter') {
            $line = $script:inputBuf.Trim()
            $script:inputBuf = ''
            Show-Prompt
            if ($line) { return $line }
        } elseif ($k.Key -eq 'Backspace') {
            if ($script:inputBuf.Length) { $script:inputBuf = $script:inputBuf.Substring(0, $script:inputBuf.Length - 1); [Console]::Write("`b `b") }
        } elseif ($k.KeyChar -ge ' ') {
            $script:inputBuf += $k.KeyChar
            [Console]::Write($k.KeyChar)
        }
    }
    return $null
}

function Format-Player($p) {
    if ($p.InGame) { return "$($p.Name) (in game)" }
    if ($p.Downloading) { return "$($p.Name) (getting map)" }
    if ($p.NoMap) { return "$($p.Name) (no map)" }
    return $p.Name
}

function Show-Lobby($state) {
    if ($script:ui) { Update-GuiLobby $state; return }
    Say "--- $($state.Game) on $($state.Map)  (engine $($state.Engine))" Cyan
    $teams = @($state.Players | ForEach-Object Team) + @($state.Bots | ForEach-Object Team) | Where-Object { $_ -gt 0 } | Sort-Object -Unique
    foreach ($t in $teams) {
        $members = @($state.Players | Where-Object Team -eq $t | ForEach-Object { Format-Player $_ }) + @($state.Bots | Where-Object Team -eq $t | ForEach-Object { "$($_.Name) [bot]" })
        Say "    Team ${t}: $($members -join ', ')" Cyan
    }
    $specs = @($state.Players | Where-Object Team -eq 0 | ForEach-Object { Format-Player $_ })
    if ($specs.Count) { Say "    Spectators: $($specs -join ', ')" Cyan }
}

# ---------------------------------------------------------------- wire protocol: "TYPE {json}\n"
# Map data goes as "CHUNK <base64>\n" without JSON (Windows PowerShell can't parse JSON over 2 MB).

$chunkSize = 128KB

function New-Conn($tcp) {
    $tcp.NoDelay = $true
    $tcp.SendBufferSize = 1MB
    [pscustomobject]@{ Tcp = $tcp; Stream = $tcp.GetStream(); Decoder = $utf8.GetDecoder(); Buf = [Text.StringBuilder]::new(); Dead = $false; Player = $null; Transfer = $null; Tunnel = $false }
}

function Send-Raw($conn, [string]$line) {
    $bytes = $utf8.GetBytes("$line`n")
    try { $conn.Stream.Write($bytes, 0, $bytes.Length) } catch { $conn.Dead = $true }
}

function Send-Msg($conn, [string]$type, $data) {
    if ($null -eq $data) { $data = @{} }
    Send-Raw $conn "$type $(ConvertTo-Json $data -Compress -Depth 5)"
}

function Receive-Msgs($conn) {
    $lines = [Collections.Generic.List[string]]::new()
    try {
        $bytes = New-Object byte[] 64KB
        $chars = New-Object char[] 64KB
        $budget = 4MB  # per call, so a map transfer can't starve the rest of the loop
        while ($conn.Tcp.Available -gt 0 -and $budget -gt 0) {
            $n = $conn.Stream.Read($bytes, 0, $bytes.Length)
            $budget -= $n
            $c = $conn.Decoder.GetChars($bytes, 0, $n, $chars, 0)
            $start = 0
            while (($i = [Array]::IndexOf($chars, [char]10, $start, $c - $start)) -ge 0) {
                [void]$conn.Buf.Append($chars, $start, $i - $start)
                $lines.Add($conn.Buf.ToString())
                [void]$conn.Buf.Clear()
                $start = $i + 1
            }
            [void]$conn.Buf.Append($chars, $start, $c - $start)
        }
        if ($conn.Tcp.Client.Poll(0, [Net.Sockets.SelectMode]::SelectRead) -and $conn.Tcp.Available -eq 0) { $conn.Dead = $true }
    } catch { $conn.Dead = $true }
    foreach ($line in $lines) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $sp = $line.IndexOf(' ')
        if ($sp -lt 0) { [pscustomobject]@{ Type = $line; Data = $null } }
        elseif ($line.StartsWith('CHUNK ')) { [pscustomobject]@{ Type = 'CHUNK'; Data = $line.Substring(6) } }
        else { [pscustomobject]@{ Type = $line.Substring(0, $sp); Data = (ConvertFrom-Json $line.Substring($sp + 1)) } }
    }
}

# ---------------------------------------------------------------- host

function New-Password { -join (1..12 | ForEach-Object { [char](Get-Random -Minimum 97 -Maximum 123) }) }

function Get-LobbyState {
    @{
        Engine  = $script:EngineName
        Game    = $script:GameName
        Map     = $script:MapName
        Players = @($script:players | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Team = $_.Team; InGame = $_.InGame; Downloading = $_.Downloading
                        NoMap = (Test-MissingMap $_) } })
        Bots    = @($script:bots | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Team = $_.Team; Ai = $_.Ai } })
    }
}

# A player who couldn't download the current map; they stay in the lobby when the game starts.
function Test-MissingMap($p) { $p.NoMap -and $p.NoMap -eq $script:MapName }

function Publish-State {
    $state = Get-LobbyState
    foreach ($c in $script:conns) { if ($c.Player) { Send-Msg $c 'STATE' $state } }
    Show-Lobby ([pscustomobject]$state)
}

function Send-All([string]$type, $data) {
    foreach ($c in $script:conns) { if ($c.Player) { Send-Msg $c $type $data } }
}

function Send-Info([string]$text) {
    Send-All 'INFO' @{ Text = $text }
    Say $text Yellow
}

function Find-Member([string]$who) {
    $script:players | Where-Object Name -eq $who | Select-Object -First 1
    $script:bots | Where-Object Name -eq $who | Select-Object -First 1
}

# Puts newcomers on whichever of teams 1/2 is smaller.
function Get-DefaultTeam {
    $count = { param($t) @($script:players | Where-Object Team -eq $t).Count + @($script:bots | Where-Object Team -eq $t).Count }
    if ((& $count 2) -lt (& $count 1)) { return 2 }
    return 1
}

function Set-Team([string]$who, [string]$team) {
    $m = @(Find-Member $who)[0]
    if (-not $m) { Say "No player or bot called '$who'." Red; return }
    if ($team -eq 'spec') { $team = 0 }
    if ($team -notmatch '^\d+$' -or [int]$team -gt 16) { Say "Team must be 1-16 or 'spec'." Red; return }
    if ([int]$team -eq 0 -and $script:bots -contains $m) { Say "Bots can't spectate; use /unbot." Red; return }
    $m.Team = [int]$team
    Publish-State
}

function Build-HostScript($players) {
    $me = $players[0]
    $l = [Collections.Generic.List[string]]::new()
    $l.Add('[GAME]'); $l.Add('{')
    $l.Add("  GameType=$($script:GameName);")
    $l.Add("  MapName=$($script:MapName);")
    $l.Add('  StartPosType=2;')
    $l.Add('  HostIP=;')
    $l.Add("  HostPort=$Port;")
    $l.Add('  IsHost=1;')
    $l.Add("  MyPlayerName=$($me.Name);")
    $l.Add("  MyPasswd=$($me.Password);")
    $team = 0
    $maxAlly = 0
    for ($i = 0; $i -lt $players.Count; $i++) {
        $p = $players[$i]
        $l.Add("  [PLAYER$i]"); $l.Add('  {')
        $l.Add("    Name=$($p.Name);")
        $l.Add("    Password=$($p.Password);")
        if ($p.Team -eq 0) { $l.Add('    Spectator=1;') }
        else { $l.Add('    Spectator=0;'); $l.Add("    Team=$team;") }
        $l.Add('  }')
        if ($p.Team -gt 0) {
            $l.Add("  [TEAM$team]"); $l.Add('  {'); $l.Add("    TeamLeader=$i;"); $l.Add("    AllyTeam=$($p.Team - 1);"); $l.Add('  }')
            $maxAlly = [Math]::Max($maxAlly, $p.Team - 1)
            $team++
        }
    }
    for ($i = 0; $i -lt $script:bots.Count; $i++) {
        $b = $script:bots[$i]
        $l.Add("  [AI$i]"); $l.Add('  {')
        $l.Add("    Name=$($b.Name);"); $l.Add("    ShortName=$($b.Ai);"); $l.Add("    Team=$team;"); $l.Add('    Host=0;')
        $l.Add('  }')
        $l.Add("  [TEAM$team]"); $l.Add('  {'); $l.Add('    TeamLeader=0;'); $l.Add("    AllyTeam=$($b.Team - 1);"); $l.Add('  }')
        $maxAlly = [Math]::Max($maxAlly, $b.Team - 1)
        $team++
    }
    # Declare every ally team up to the highest used, so the engine doesn't renumber them.
    for ($a = 0; $a -le $maxAlly; $a++) { $l.Add("  [ALLYTEAM$a]"); $l.Add('  {'); $l.Add('    NumAllies=0;'); $l.Add('  }') }
    $l.Add('  [MODOPTIONS]'); $l.Add('  {'); $l.Add('  }')
    $l.Add('}')
    $l -join "`r`n"
}

function Show-HostHelp {
    Say @'
Commands (anything else is chat):
  /team <name> <n|spec>   move a player or bot     /ffa             everyone on their own team
  /spec <name>            make a player spectate   /play <name>     put a spectator back on a team
  /bot <team> [difficulty] add a CircuitAI bot      /unbot <name>    remove a bot
  /map <map name>         change map               /game <tag|name> change game (default zk:stable)
  /kick <name>            remove a player          /start           launch the game for everyone
  /quit                   close the lobby
Players can use /spec, /play and /team <n> on themselves, and /quit to leave.
Players missing the map get it from you automatically (Cloudflare tunnel players download it from
springfiles instead; if it isn't there, they stay in the lobby when the game starts).
Everyone returns to this lobby when their game window closes.
'@ DarkGray
}

# Back on a team: the smaller of teams 1/2.
function Set-Playing([string]$who) {
    $m = @(Find-Member $who)[0]
    if ($m -and $m.Team -gt 0) { Say "$who is already playing." Red; return }
    Set-Team $who ([string](Get-DefaultTeam))
}

# ---------------------------------------------------------------- host: sending maps

function Start-MapSend($conn, [string]$map) {
    if ($map -ne $script:MapName) { return }  # stale request from before a /map change
    $path = Find-MapArchive $map
    if (-not $path) { Send-Msg $conn 'NOMAP' @{ Map = $map }; return }
    Stop-MapSend $conn
    $fs = [IO.File]::OpenRead($path)
    $conn.Transfer = [pscustomobject]@{ File = $fs; Map = $map }
    $conn.Player.Downloading = $true
    Send-Msg $conn 'MAPFILE' @{ Map = $map; File = (Split-Path $path -Leaf); Size = $fs.Length }
    Send-Info "Sending $map to $($conn.Player.Name) ($([Math]::Ceiling($fs.Length / 1MB)) MB)..."
    Publish-State
}

function Stop-MapSend($conn) {
    if (-not $conn.Transfer) { return }
    $conn.Transfer.File.Dispose()
    $conn.Transfer = $null
    if ($conn.Player) { $conn.Player.Downloading = $false }
}

# Called every tick: sends only what the socket will take, so the lobby stays responsive.
function Send-MapChunks($conn) {
    $buf = New-Object byte[] $chunkSize
    for ($k = 0; $k -lt 8 -and $conn.Transfer -and -not $conn.Dead -and $conn.Tcp.Client.Poll(0, [Net.Sockets.SelectMode]::SelectWrite); $k++) {
        $n = $conn.Transfer.File.Read($buf, 0, $buf.Length)
        if ($n -le 0) {
            Send-Msg $conn 'MAPDONE' $null
            Stop-MapSend $conn
            Send-Info "$($conn.Player.Name) has the map."
            Publish-State
            return
        }
        Send-Raw $conn ('CHUNK ' + [Convert]::ToBase64String($buf, 0, $n))
    }
}

function Invoke-HostCommand([string]$line, $from) {
    $isHost = $from -eq $script:players[0]
    switch -regex ($line) {
        '^/team\s+(\d+|spec)$' { Set-Team $from.Name $Matches[1]; return }
        '^/spec$' { Set-Team $from.Name 'spec'; return }
        '^/play$' { Set-Playing $from.Name; return }
    }
    if (-not $isHost) {
        if ($line.StartsWith('/')) { Send-Info "$($from.Name) tried '$line' (players can use /spec, /play and /team <n>)" }
        else { Send-All 'CHAT' @{ From = $from.Name; Text = $line }; Say "<$($from.Name)> $line" }
        return
    }
    switch -regex ($line) {
        '^/team\s+(\S+)\s+(\d+|spec)$' { Set-Team $Matches[1] $Matches[2]; return }
        '^/spec\s+(\S+)$' { Set-Team $Matches[1] 'spec'; return }
        '^/play\s+(\S+)$' { Set-Playing $Matches[1]; return }
        '^/ffa$' {
            $t = 1
            foreach ($m in @($script:players | Where-Object Team -gt 0) + @($script:bots)) { $m.Team = $t; $t++ }
            Publish-State; return
        }
        '^/bot\s+(\d+)(?:\s+(\S+))?$' {
            $diff = if ($Matches[2]) { $Matches[2] } else { 'Normal' }
            $diff = $aiDifficulties | Where-Object { $_ -eq $diff } | Select-Object -First 1
            if (-not $diff) { Say "Difficulty must be one of: $($aiDifficulties -join ', ')" Red; return }
            $n = 1
            while (Find-Member "$diff$n") { $n++ }
            $script:bots.Add([pscustomobject]@{ Name = "$diff$n"; Team = [int]$Matches[1]; Ai = (Get-BotShortName $diff) })
            Publish-State; return
        }
        '^/unbot\s+(\S+)$' {
            $b = $script:bots | Where-Object Name -eq $Matches[1] | Select-Object -First 1
            if ($b) { [void]$script:bots.Remove($b); Publish-State } else { Say "No bot called '$($Matches[1])'." Red }
            return
        }
        '^/map\s+(.+)$' {
            $script:MapName = $Matches[1].Trim()
            foreach ($c in $script:conns) { if ($c.Transfer) { Stop-MapSend $c; Send-Msg $c 'MAPABORT' $null } }
            foreach ($p in $script:players) { $p.Downloading = $false }  # downloads of the old map no longer matter
            Confirm-Content $script:GameName $script:MapName
            Publish-State; return
        }
        '^/game\s+(.+)$' { $script:GameName = Resolve-GameName $Matches[1].Trim(); Confirm-Content $script:GameName $script:MapName; Publish-State; return }
        '^/kick\s+(\S+)$' {
            $c = $script:conns | Where-Object { $_.Player -and $_.Player.Name -eq $Matches[1] } | Select-Object -First 1
            if ($c) { Send-Msg $c 'ERROR' @{ Text = 'You were kicked from the lobby.' }; $c.Dead = $true } else { Say "No remote player called '$($Matches[1])'." Red }
            return
        }
        '^/start$' { Start-Match; return }
        '^/quit$' { $script:quit = $true; return }
        '^/help$' { Show-HostHelp; return }
        '^/' { Say "Unknown command. /help lists them." Red; return }
    }
    Send-All 'CHAT' @{ From = $from.Name; Text = $line }
    Say "<$($from.Name)> $line"
}

function Start-Match {
    $busy = @($script:players | Where-Object InGame | ForEach-Object Name)
    if ($busy.Count) { Say "Still in the last game: $($busy -join ', '). Wait for them to close it, or /kick them." Red; return }
    $busy = @($script:players | Where-Object Downloading | ForEach-Object Name)
    if ($busy.Count) { Say "Still getting the map: $($busy -join ', '). Wait for them, or /kick them." Red; return }
    $going = @($script:players | Where-Object { -not (Test-MissingMap $_) })
    if (-not (@($going | Where-Object Team -gt 0).Count + $script:bots.Count)) { Say "Nobody is on a team." Red; return }
    $hostScript = Build-HostScript $going
    foreach ($c in $script:conns) {
        if ($c.Player -and $going -contains $c.Player) { Send-Msg $c 'START' @{ Password = $c.Player.Password }; $c.Player.InGame = $true }
    }
    $left = @($script:players | Where-Object { $going -notcontains $_ } | ForEach-Object Name)
    if ($left.Count) { Send-Info "Starting the game without $($left -join ', '), who couldn't get the map..." }
    else { Send-Info "Starting the game..." }
    $script:players[0].InGame = $true
    $script:hostGame = Start-Spring $hostScript
}

# ---------------------------------------------------------------- host: UPnP

$upnpDescription = 'Zero-K Direct'

# Asks the router to forward $Port (TCP and UDP) to this PC while the lobby is open; Close-UpnpPort undoes it.
# Without a UPnP router (UPnP off, or a phone or second router in between) the port has to be opened another way.
function Open-UpnpPort {
    $script:upnp = $null
    if ($NoUpnp) { return }
    Say "Asking the router to open port $Port (UPnP)..." DarkGray
    $maps = $null
    try { $maps = (New-Object -ComObject HNetCfg.NATUPnP).StaticPortMappingCollection } catch {}
    if (-not $maps) { Say "No UPnP router answered, so port $Port wasn't opened automatically." Yellow; return }
    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $myIp = if ($route) { Get-NetIPAddress -InterfaceIndex $route.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty IPAddress }
    if (-not $myIp) { Say "Couldn't tell this PC's network address, so port $Port wasn't opened automatically." Yellow; return }
    $open = @()
    $ours = @()  # only these are removed at the end: never a forward someone set up by hand
    $externalIp = $null
    foreach ($proto in 'TCP', 'UDP') {
        try {
            $existing = $null
            try { $existing = $maps.Item($Port, $proto) } catch {}
            if ($existing -and $existing.InternalClient -eq $myIp) {
                if ($existing.Description -eq $upnpDescription) { $ours += $proto }  # left over from a lobby whose window was closed
                $open += $proto
                $externalIp = $existing.ExternalIPAddress
                continue
            }
            if ($existing -and $existing.Description -ne $upnpDescription) {
                Say "The router already forwards port $Port/$proto to $($existing.InternalClient); leaving that alone." Red
                continue
            }
            if ($existing) { $maps.Remove($Port, $proto) }  # ours, for this PC's old address
            $m = $maps.Add($Port, $proto, $Port, $myIp, $true, $upnpDescription)
            $externalIp = $m.ExternalIPAddress
            $open += $proto
            $ours += $proto
        } catch {
            $err = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            Say "The router wouldn't open port $Port/${proto}: $err" Red
        }
    }
    $script:upnp = [pscustomobject]@{ Maps = $maps; Ours = $ours; Open = $open; ExternalIp = $externalIp }
    if ($open.Count -eq 2) { Say "The router forwards port $Port (TCP+UDP) to this PC until the lobby closes." Green }
}

function Close-UpnpPort {
    if (-not $script:upnp) { return }
    foreach ($proto in $script:upnp.Ours) { try { $script:upnp.Maps.Remove($Port, $proto) } catch {} }
    $script:upnp = $null
}

# ---------------------------------------------------------------- Cloudflare quick tunnel
# Behind a phone or a second router nothing can be forwarded, so the host can run cloudflared instead: Cloudflare
# gives it a public https://<words>.trycloudflare.com address. That carries only HTTP, so both ends wrap the lobby
# (TCP) and the game (UDP) in one WebSocket. The relay runs on its own threads (game packets can't wait for the
# lobby's 50ms tick), compiled from C# on first use. Maps are never sent through the tunnel (Cloudflare's terms
# don't allow serving large files on its free plan); tunnel players download missing maps from springfiles.

$bridgeSource = @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace ZkDirect
{
    // One WebSocket carrying a lobby connection's bytes and the game's UDP datagrams, each binary message being
    // [channel][data]: channel 0 is the lobby stream, 1 one datagram.
    public class Bridge
    {
        readonly Stream ws;
        readonly bool mask;  // clients mask what they send, servers don't
        readonly TcpClient wsTcp, lobby;
        readonly UdpClient udp;
        volatile IPEndPoint udpPeer;  // where datagrams from the WebSocket go; the client side learns it from the engine
        readonly object writeLock = new object();
        readonly Random random = new Random();
        Timer pinger;
        int closed;
        public Action OnClosed;
        public bool IsClosed { get { return closed != 0; } }

        public Bridge(Stream ws, bool mask, TcpClient wsTcp, TcpClient lobby, UdpClient udp, IPEndPoint udpPeer)
        {
            this.ws = ws; this.mask = mask; this.wsTcp = wsTcp; this.lobby = lobby; this.udp = udp; this.udpPeer = udpPeer;
            lobby.NoDelay = true;
            wsTcp.NoDelay = true;
            IgnoreUdpResets(udp);
        }

        // Otherwise Windows fails the next receive when a datagram bounced (e.g. the engine had just closed).
        public static void IgnoreUdpResets(UdpClient u) { u.Client.IOControl(-1744830452, new byte[4], null); }

        public void Start()
        {
            Run(LobbyToWs); Run(UdpToWs); Run(WsToLocal);
            // Cloudflare drops WebSockets that are quiet for 100 seconds, e.g. a lobby where nobody talks
            pinger = new Timer(delegate { try { Send(9, -1, new byte[0], 0, 0); } catch { Close(); } }, null, 20000, 20000);
        }

        void Run(ThreadStart body)
        {
            var t = new Thread(delegate () { try { body(); } catch { } Close(); });
            t.IsBackground = true;
            t.Start();
        }

        void LobbyToWs()
        {
            var s = lobby.GetStream();
            var buf = new byte[16384];
            int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0) Send(2, 0, buf, 0, n);
        }

        void UdpToWs()
        {
            var buf = new byte[65536];
            while (closed == 0)
            {
                EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                int n;
                try { n = udp.Client.ReceiveFrom(buf, ref from); }
                catch (SocketException e) { if (e.SocketErrorCode == SocketError.ConnectionReset) continue; throw; }
                if (mask) udpPeer = (IPEndPoint)from;
                Send(2, 1, buf, 0, n);
            }
        }

        void WsToLocal()
        {
            var s = lobby.GetStream();
            byte[] msg;
            while ((msg = ReadMessage(ws, this)) != null)
            {
                if (msg.Length == 0) continue;
                if (msg[0] == 0) s.Write(msg, 1, msg.Length - 1);
                else if (msg[0] == 1) { var peer = udpPeer; if (peer != null) udp.Client.SendTo(msg, 1, msg.Length - 1, SocketFlags.None, peer); }
            }
        }

        public void Send(int opcode, int channel, byte[] data, int off, int len)
        {
            int plen = len + (channel >= 0 ? 1 : 0);
            var f = new byte[14 + plen];
            int p = 0;
            f[p++] = (byte)(0x80 | opcode);
            int m = mask ? 0x80 : 0;
            if (plen < 126) f[p++] = (byte)(m | plen);
            else if (plen < 65536) { f[p++] = (byte)(m | 126); f[p++] = (byte)(plen >> 8); f[p++] = (byte)plen; }
            else { f[p++] = (byte)(m | 127); for (int i = 7; i >= 0; i--) f[p++] = (byte)(i < 4 ? plen >> (8 * i) : 0); }
            lock (writeLock)
            {
                var key = new byte[4];
                if (mask) { random.NextBytes(key); Buffer.BlockCopy(key, 0, f, p, 4); p += 4; }
                int start = p;
                if (channel >= 0) f[p++] = (byte)channel;
                Buffer.BlockCopy(data, off, f, p, len);
                p += len;
                if (mask) for (int i = 0; i < plen; i++) f[start + i] ^= key[i & 3];
                ws.Write(f, 0, p);
            }
        }

        // The next data message, answering pings on the way; null once the WebSocket is closed.
        static byte[] ReadMessage(Stream s, Bridge replyTo)
        {
            var msg = new MemoryStream();
            while (true)
            {
                byte[] h = ReadExact(s, 2);
                if (h == null) return null;
                bool fin = (h[0] & 0x80) != 0;
                int op = h[0] & 0x0F;
                long len = h[1] & 0x7F;
                if (len == 126) { var e = ReadExact(s, 2); if (e == null) return null; len = (e[0] << 8) | e[1]; }
                else if (len == 127) { var e = ReadExact(s, 8); if (e == null) return null; len = 0; for (int i = 0; i < 8; i++) len = (len << 8) | e[i]; }
                if (len > (16 << 20)) return null;
                byte[] key = null;
                if ((h[1] & 0x80) != 0) { key = ReadExact(s, 4); if (key == null) return null; }
                byte[] payload = ReadExact(s, (int)len);
                if (payload == null) return null;
                if (key != null) for (int i = 0; i < payload.Length; i++) payload[i] ^= key[i & 3];
                if (op == 8) return null;
                if (op == 9) { replyTo.Send(10, -1, payload, 0, payload.Length); continue; }
                if (op == 10) continue;
                msg.Write(payload, 0, payload.Length);
                if (fin) return msg.ToArray();
            }
        }

        static byte[] ReadExact(Stream s, int n)
        {
            var b = new byte[n];
            for (int got = 0; got < n; )
            {
                int r = s.Read(b, got, n - got);
                if (r <= 0) return null;
                got += r;
            }
            return b;
        }

        // HTTP headers, read a byte at a time so nothing after them is consumed.
        public static string ReadHeaders(Stream s)
        {
            var sb = new StringBuilder();
            while (!sb.ToString().EndsWith("\r\n\r\n"))
            {
                if (sb.Length > 16384) throw new IOException("HTTP headers too long");
                int b = s.ReadByte();
                if (b < 0) throw new IOException("Connection closed during the WebSocket handshake");
                sb.Append((char)b);
            }
            return sb.ToString();
        }

        public static string AcceptKey(string key)
        {
            using (var sha = SHA1.Create())
                return Convert.ToBase64String(sha.ComputeHash(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        }

        public void Close()
        {
            if (Interlocked.Exchange(ref closed, 1) != 0) return;
            if (pinger != null) pinger.Dispose();
            try { ws.Close(); } catch { }
            try { wsTcp.Close(); } catch { }
            try { lobby.Close(); } catch { }
            try { udp.Close(); } catch { }
            var a = OnClosed;
            if (a != null) a();
        }
    }

    // Host side: the WebSocket server cloudflared forwards to. Each WebSocket becomes a TCP connection to the lobby
    // and a UDP socket talking to the game, both from 127.0.0.1, so the lobby and the engine see an ordinary player.
    public class TunnelHost
    {
        static readonly ConcurrentDictionary<int, bool> lobbyPorts = new ConcurrentDictionary<int, bool>();
        readonly TcpListener listener;
        readonly int lobbyPort;
        readonly List<Bridge> bridges = new List<Bridge>();
        public int Port { get; private set; }

        // Whether a lobby connection from 127.0.0.1:port came through the tunnel.
        public static bool IsTunneled(int port) { return lobbyPorts.ContainsKey(port); }

        public TunnelHost(int lobbyPort)
        {
            this.lobbyPort = lobbyPort;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            Port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var t = new Thread(AcceptLoop);
            t.IsBackground = true;
            t.Start();
        }

        void AcceptLoop()
        {
            while (true)
            {
                TcpClient c;
                try { c = listener.AcceptTcpClient(); } catch { return; }
                var t = new Thread(delegate () { Handle(c); });
                t.IsBackground = true;
                t.Start();
            }
        }

        void Handle(TcpClient c)
        {
            try
            {
                Stream s = c.GetStream();
                string req = Bridge.ReadHeaders(s);
                var key = Regex.Match(req, @"^Sec-WebSocket-Key:\s*(\S+)", RegexOptions.Multiline | RegexOptions.IgnoreCase);
                if (!key.Success)
                {
                    var page = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n" +
                        "This is a Zero-K Direct lobby. To join, paste this page's address into zk-direct.\r\n");
                    s.Write(page, 0, page.Length);
                    c.Close();
                    return;
                }
                var ok = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " +
                    Bridge.AcceptKey(key.Groups[1].Value) + "\r\n\r\n");
                s.Write(ok, 0, ok.Length);
                // bound before connecting, so the port is registered before the lobby can see the connection
                var lobby = new TcpClient(new IPEndPoint(IPAddress.Loopback, 0));
                int lp = ((IPEndPoint)lobby.Client.LocalEndPoint).Port;
                lobbyPorts[lp] = true;
                lobby.Connect(IPAddress.Loopback, lobbyPort);
                var udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
                var b = new Bridge(s, false, c, lobby, udp, new IPEndPoint(IPAddress.Loopback, lobbyPort));
                b.OnClosed = delegate { bool x; lobbyPorts.TryRemove(lp, out x); lock (bridges) bridges.Remove(b); };
                lock (bridges) bridges.Add(b);
                b.Start();
            }
            catch { c.Close(); }
        }

        public void Stop()
        {
            listener.Stop();
            Bridge[] all;
            lock (bridges) all = bridges.ToArray();
            foreach (var b in all) b.Close();
        }
    }

    // Join side: a local stand-in for the host. The lobby connects to 127.0.0.1:Port over TCP and the engine sends
    // the game there over UDP (the same port number, as with a real host); both go through one WebSocket.
    public class TunnelClient
    {
        readonly TcpListener listener;
        readonly UdpClient udp;
        TcpClient wsTcp;
        Bridge bridge;
        volatile bool closing;
        public int Port { get; private set; }
        public volatile bool Ready;
        public volatile bool Waiting;  // the address doesn't resolve yet; still trying
        public volatile string Error;
        public bool IsClosed { get { return closing || (bridge != null && bridge.IsClosed); } }

        public TunnelClient(string host, int port, bool tls, string path)
        {
            for (int i = 0; ; i++)
            {
                listener = new TcpListener(IPAddress.Loopback, 0);
                listener.Start();
                Port = ((IPEndPoint)listener.LocalEndpoint).Port;
                try { udp = new UdpClient(new IPEndPoint(IPAddress.Loopback, Port)); break; }
                catch (SocketException) { listener.Stop(); if (i >= 20) throw; }
            }
            var t = new Thread(delegate () { Connect(host, port, tls, path); });
            t.IsBackground = true;
            t.Start();
        }

        void Connect(string host, int port, bool tls, string path)
        {
            try
            {
                // Looked up too soon after the host started, a new tunnel address doesn't exist yet, and Windows then
                // remembers that for a minute; so keep trying for a while.
                var started = DateTime.UtcNow;
                while (true)
                {
                    wsTcp = new TcpClient();
                    try { wsTcp.Connect(host, port); break; }
                    catch (SocketException e)
                    {
                        wsTcp.Close();
                        if (e.SocketErrorCode != SocketError.HostNotFound || closing || (DateTime.UtcNow - started).TotalSeconds > 90) throw;
                        Waiting = true;
                        Thread.Sleep(3000);
                    }
                }
                Waiting = false;
                Stream s = wsTcp.GetStream();
                if (tls)
                {
                    var ssl = new SslStream(s);
                    ssl.AuthenticateAsClient(host, null, SslProtocols.Tls12, true);
                    s = ssl;
                }
                string key = Convert.ToBase64String(Guid.NewGuid().ToByteArray());
                var req = Encoding.ASCII.GetBytes("GET " + path + " HTTP/1.1\r\nHost: " + host + "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                    "Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\nUser-Agent: zk-direct\r\n\r\n");
                s.Write(req, 0, req.Length);
                string resp = Bridge.ReadHeaders(s);
                string status = resp.Substring(0, resp.IndexOf('\r'));
                if (!status.Contains(" 101 ") || resp.IndexOf(Bridge.AcceptKey(key), StringComparison.Ordinal) < 0)
                    throw new IOException(status.Contains(" 530 ") || status.Contains(" 404 ")
                        ? "there's no lobby at that address any more (a tunnel address changes every time the host starts a lobby)"
                        : "it isn't a Zero-K Direct lobby (it answered '" + status + "')");
                Ready = true;
                var lobby = listener.AcceptTcpClient();
                listener.Stop();
                bridge = new Bridge(s, true, wsTcp, lobby, udp, null);
                if (closing) { bridge.Close(); return; }
                bridge.Start();
            }
            catch (Exception e)
            {
                if (!closing) Error = e is SocketException && ((SocketException)e).SocketErrorCode == SocketError.HostNotFound
                    ? "there's no such address (check for typos)"
                    : e.Message;
                Close();
            }
        }

        public void Close()
        {
            closing = true;
            try { listener.Stop(); } catch { }
            var b = bridge;
            if (b != null) b.Close();
            else { try { udp.Close(); } catch { } try { if (wsTcp != null) wsTcp.Close(); } catch { } }
        }
    }

    // cloudflared running a quick tunnel to a local port; Url is set once Cloudflare has assigned the address.
    public class Cloudflared
    {
        readonly Process proc;
        readonly Queue<string> tail = new Queue<string>();
        public volatile string Url;

        public Cloudflared(string exe, int port)
        {
            var psi = new ProcessStartInfo(exe, "tunnel --no-autoupdate --url http://127.0.0.1:" + port);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardError = true;
            psi.RedirectStandardOutput = true;
            proc = Process.Start(psi);
            KillWithUs(proc);
            Read(proc.StandardError);
            Read(proc.StandardOutput);
        }

        void Read(StreamReader r)
        {
            var t = new Thread(delegate ()
            {
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    lock (tail) { tail.Enqueue(line); if (tail.Count > 15) tail.Dequeue(); }
                    var m = Regex.Match(line, @"https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com");
                    if (m.Success && Url == null) Url = m.Value;
                }
            });
            t.IsBackground = true;
            t.Start();
        }

        public bool HasExited { get { return proc.HasExited; } }
        public string Log { get { lock (tail) return string.Join("\n", tail.ToArray()); } }
        public void Stop() { try { if (!proc.HasExited) proc.Kill(); } catch { } }

        // A job object that ends cloudflared when this process ends, even if its window is just closed.
        static IntPtr job;

        [StructLayout(LayoutKind.Sequential)]
        struct JobLimits
        {
            public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass, SchedulingClass;
            public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
            public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JobLimits info, int size);
        [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        static void KillWithUs(Process p)
        {
            lock (typeof(Cloudflared))
            {
                if (job == IntPtr.Zero)
                {
                    job = CreateJobObject(IntPtr.Zero, null);
                    var info = new JobLimits();
                    info.LimitFlags = 0x2000;  // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
                    SetInformationJobObject(job, 9, ref info, Marshal.SizeOf(typeof(JobLimits)));
                }
            }
            AssignProcessToJobObject(job, p.Handle);
        }
    }
}
'@

function Initialize-Bridge {
    if (-not ('ZkDirect.Bridge' -as [type])) { Add-Type -TypeDefinition $bridgeSource }
}

# cloudflared.exe from -Cloudflared, the last one used, PATH, next to this script, its installer's folder or Downloads.
function Find-Cloudflared {
    $candidates = @(
        $Cloudflared
        Get-SavedSetting $cloudflaredFile
        (Get-Command cloudflared -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        Get-ChildItem $scriptDir -Filter 'cloudflared*.exe' -ErrorAction SilentlyContinue | ForEach-Object FullName
        foreach ($pf in ${env:ProgramFiles(x86)}, $env:ProgramFiles) { if ($pf) { Join-Path $pf 'cloudflared\cloudflared.exe' } }
        Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -Filter 'cloudflared*.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | ForEach-Object FullName
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c -PathType Leaf)) {
            $c = (Resolve-Path $c).Path
            Save-Setting $cloudflaredFile $c
            return $c
        }
    }
    if ($Cloudflared) { throw "No cloudflared at '$Cloudflared'." }
}

function Start-Tunnel {
    $script:tunnel = $null
    if ($NoTunnel) { return }
    $exe = Find-Cloudflared
    if (-not $exe) { return }
    Say "Starting a Cloudflare quick tunnel..." DarkGray
    Initialize-Bridge
    $bridge = New-Object ZkDirect.TunnelHost($Port)
    try { $proc = New-Object ZkDirect.Cloudflared($exe, $bridge.Port) }
    catch { $bridge.Stop(); Say "Couldn't start cloudflared ($exe): $($_.Exception.InnerException.Message)" Red; return }
    $script:tunnel = [pscustomobject]@{ Bridge = $bridge; Proc = $proc; Url = $null; Deadline = (Get-Date).AddSeconds(45); NextCheck = [datetime]::MinValue }
}

# Called every tick: announces the address once it works, and notices cloudflared stopping.
function Step-Tunnel {
    $t = $script:tunnel
    if (-not $t) { return }
    # Cloudflare publishes the name a moment after cloudflared prints it. A player who looked it up before then would
    # be told it doesn't exist for a minute (Windows caches that), so announce it once public DNS has it; asking
    # 1.1.1.1 directly keeps this PC's own cache out of it.
    if (-not $t.Url -and $t.Proc.Url -and (Get-Date) -ge $t.NextCheck) {
        $t.NextCheck = (Get-Date).AddSeconds(1)
        $resolves = $true
        if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
            try { [void](Resolve-DnsName ([Uri]$t.Proc.Url).Host -Server 1.1.1.1 -DnsOnly -QuickTimeout -ErrorAction Stop) } catch { $resolves = $false }
        }
        if ($resolves -or (Get-Date) -gt $t.Deadline) {
            $t.Url = $t.Proc.Url
            Say "Cloudflare tunnel ready. Friends anywhere can join with:" Green
            Say "    $($t.Url)" Green
            Say "  (it changes every time you host. Maps aren't sent through it: tunnel players download missing ones from springfiles.)" DarkGray
        }
    }
    if ($t.Proc.HasExited) {
        Say "cloudflared stopped, so the tunnel is closed. Its last words:`n$($t.Proc.Log)" Red
        Stop-Tunnel
    } elseif (-not $t.Url -and (Get-Date) -gt $t.Deadline) {
        Say "Cloudflare didn't assign a tunnel address. cloudflared's last words:`n$($t.Proc.Log)" Red
        Stop-Tunnel
    }
}

function Stop-Tunnel {
    if (-not $script:tunnel) { return }
    $script:tunnel.Proc.Stop()
    $script:tunnel.Bridge.Stop()
    $script:tunnel = $null
}

function Test-Tunneled($conn) {
    $ep = $conn.Tcp.Client.RemoteEndPoint
    $script:tunnel -and [Net.IPAddress]::IsLoopback($ep.Address) -and [ZkDirect.TunnelHost]::IsTunneled($ep.Port)
}

function Show-JoinInfo {
    $ips = @()
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress
    } catch {}
    $public = $null
    try { $public = (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 3).ToString().Trim() } catch {}
    $forwarded = $script:upnp -and $script:upnp.Open.Count -eq 2
    if ($forwarded -and $public -and $script:upnp.ExternalIp -and $script:upnp.ExternalIp -ne $public) {
        # e.g. a phone or a second router between this PC's router and the internet, or the ISP's own NAT
        Say "Your router's internet address ($($script:upnp.ExternalIp)) isn't your public one ($public): something in front of it still blocks friends. Use a VPN such as Tailscale, or have someone else host." Yellow
        $forwarded = $false
    }
    Say "Lobby open on TCP+UDP port $Port. Friends double-click zk-direct.cmd and join one of:" Green
    if ($public) {
        $note = if ($forwarded) { '(internet)' } else { "(internet: needs port $Port TCP+UDP forwarded to this PC)" }
        Say "    ${public}:$Port      $note" Green
    }
    foreach ($ip in $ips) { Say "    ${ip}:$Port" Green }
    if ($script:tunnel) { Say "    or the Cloudflare tunnel's address, coming up below" Green }
    elseif (-not $forwarded -and -not $NoTunnel) {
        Say "  No way to open the port (e.g. phone tethering)? Download cloudflared-windows-amd64.exe from" Yellow
        Say "  https://github.com/cloudflare/cloudflared/releases and host again: players then join through a Cloudflare tunnel." Yellow
    }
    Say "  (or 'zk-direct.cmd join <address>' in a terminal, or a zkjoinbk://<address> link). Type /help for commands." Green
    $script:hostAddress = if ($public) { "${public}:$Port" } elseif (@($ips).Count) { "$(@($ips)[0]):$Port" }  # for the window's invite link
}

# A host lobby; Step-Host advances it without blocking, from the terminal loop or the window's timer.
# Close-Host undoes everything Open-Host set up, including when Open-Host failed halfway.
function Open-Host {
    $script:EngineName = Split-Path $script:EngineDir -Leaf
    $script:GameName = Resolve-GameName $Game
    $script:MapName = $Map
    Confirm-Content $script:GameName $script:MapName

    $script:players = [Collections.Generic.List[object]]::new()
    $script:bots = [Collections.Generic.List[object]]::new()
    $script:conns = [Collections.Generic.List[object]]::new()
    $script:quit = $false
    $script:hostGame = $null
    $script:hostAddress = $null
    $script:players.Add([pscustomobject]@{ Name = $Name; Team = 1; Password = (New-Password); InGame = $false; Downloading = $false })

    $script:listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
    $script:listener.Start()
    Open-UpnpPort
    Start-Tunnel
    Show-JoinInfo
    Publish-State
}

function Step-Host {
    while ($script:listener.Pending()) { $script:conns.Add((New-Conn $script:listener.AcceptTcpClient())) }

    foreach ($c in @($script:conns)) {
        foreach ($msg in @(Receive-Msgs $c)) {
            if ($msg.Type -eq 'HELLO' -and -not $c.Player) {
                $n = [string]$msg.Data.Name
                if ($n -notmatch $namePattern) { Send-Msg $c 'ERROR' @{ Text = "Invalid name '$n' (letters, digits, _ - [ ] only)." }; $c.Dead = $true }
                elseif (Find-Member $n) { Send-Msg $c 'ERROR' @{ Text = "The name '$n' is taken." }; $c.Dead = $true }
                else {
                    $c.Tunnel = Test-Tunneled $c
                    $c.Player = [pscustomobject]@{ Name = $n; Team = (Get-DefaultTeam); Password = (New-Password); InGame = $false; Downloading = $false; NoMap = $null }
                    $script:players.Add($c.Player)
                    Send-Info $(if ($c.Tunnel) { "$n joined (through the Cloudflare tunnel)." } else { "$n joined." })
                    Publish-State
                }
            } elseif ($msg.Type -eq 'CHAT' -and $c.Player) {
                Invoke-HostCommand ([string]$msg.Data.Text) $c.Player
            } elseif ($msg.Type -eq 'BACK' -and $c.Player) {
                $c.Player.InGame = $false
                Send-Info "$($c.Player.Name) is back in the lobby."
                Publish-State
            } elseif ($msg.Type -eq 'NEEDMAP' -and $c.Player) {
                # never through the tunnel; the player downloads it instead
                if ($c.Tunnel) { Send-Msg $c 'NOMAP' @{ Map = [string]$msg.Data.Map } }
                else { Start-MapSend $c ([string]$msg.Data.Map) }
            } elseif ($msg.Type -eq 'MAPSTATE' -and $c.Player -and $msg.Data.Map -eq $script:MapName) {
                # a player downloading the map themselves: 'getting', then 'ok' or 'missing'
                $c.Player.Downloading = $msg.Data.State -eq 'getting'
                $c.Player.NoMap = if ($msg.Data.State -eq 'missing') { $script:MapName } else { $null }
                if ($c.Player.NoMap) { Send-Info "$($c.Player.Name) couldn't download $($script:MapName), so stays in the lobby when the game starts." }
                elseif ($msg.Data.State -eq 'ok') { Send-Info "$($c.Player.Name) has the map." }
                Publish-State
            }
        }
        if ($c.Transfer) { Send-MapChunks $c }
        if ($c.Dead) {
            Stop-MapSend $c
            $c.Tcp.Close()
            [void]$script:conns.Remove($c)
            if ($c.Player) { [void]$script:players.Remove($c.Player); Send-Info "$($c.Player.Name) left."; Publish-State }
        }
    }

    Step-Tunnel

    if ($script:hostGame -and $script:hostGame.HasExited) {
        $script:hostGame = $null
        $script:players[0].InGame = $false
        Send-Info "$($script:players[0].Name) (host) is back in the lobby."
        Publish-State
    }
}

function Close-Host {
    if ($script:conns) { foreach ($c in @($script:conns)) { Stop-MapSend $c; $c.Tcp.Close() } }
    $script:conns = $null
    if ($script:listener) { $script:listener.Stop(); $script:listener = $null }
    Stop-Tunnel
    Close-UpnpPort
}

# Other players in the lobby (not counting the host or bots).
function Get-HostGuestCount { @($script:conns | Where-Object { $_.Player }).Count }

function Start-Host {
    try {
        Open-Host
        while (-not $script:quit) {
            Step-Host
            $line = Read-InputLine
            if ($line) { Invoke-HostCommand $line $script:players[0] }
            Start-Sleep -Milliseconds 50
        }
    } finally { Close-Host }
}

# ---------------------------------------------------------------- join

# A join session; Step-Join advances it without blocking, from the terminal loop or the window's timer.
function Open-Join([string]$address) {
    $addr = $address.Trim() -replace '^zkjoin(bk)?://', '' -replace '/+$', ''
    $tcp = New-Object Net.Sockets.TcpClient
    $bridge = $null
    if ($addr -match '^(https?|wss?)://' -or $addr -match '\.trycloudflare\.com$') {
        # A Cloudflare tunnel: the lobby and game go to a local bridge, which relays them over a WebSocket.
        $uri = [Uri]$(if ($addr -match '^[a-z]+://') { $addr } else { "https://$addr" })
        $display = "$($uri.Scheme)://$($uri.Authority)"
        Say "Connecting to $display (Cloudflare tunnel)..." Yellow
        Initialize-Bridge
        $bridge = New-Object ZkDirect.TunnelClient($uri.Host, $uri.Port, ($uri.Scheme -in 'https', 'wss'), $uri.PathAndQuery)
        $hostName = '127.0.0.1'
        $hostPort = $bridge.Port
        $connecting = $null  # once the bridge is ready
    } else {
        $hostName = $addr
        $hostPort = $Port
        if ($addr -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $hostPort = [int]$Matches[2] }
        $display = "${hostName}:$hostPort"
        Say "Connecting to $display..." Yellow
        $connecting = $tcp.ConnectAsync($hostName, $hostPort)
    }
    [pscustomobject]@{
        HostName = $hostName; HostPort = $hostPort; Display = $display; Bridge = $bridge; Tcp = $tcp; Conn = $null; Done = $false
        Connecting = $connecting; Deadline = (Get-Date).AddSeconds($(if ($bridge) { 100 } else { 20 })); SaidWaiting = $false
        State = $null; HaveGame = $null; HaveMap = $null
        Received = @{}  # maps received this session; the engine's cache doesn't know them until it rescans
        Dl = $null; Game = $null; Downloads = [Collections.Generic.List[object]]::new()
    }
}

# pr-downloader in the background, so the lobby keeps running while it works.
function Start-Download($j, [string]$kind, [string]$what) {
    Say "Downloading $kind '$what'..." Yellow
    $p = Start-Process -PassThru -WindowStyle Hidden -FilePath (Join-Path $script:EngineDir 'pr-downloader.exe') `
        -ArgumentList '--filesystem-writepath', "`"$ZkDir`"", "--download-$kind", "`"$what`""
    [void]$p.Handle  # keeps ExitCode readable after it exits
    $j.Downloads.Add([pscustomobject]@{ Proc = $p; Kind = $kind; What = $what })
}

# Downloads a map the host can't send, telling the host so /start waits for it (or goes without this player).
function Start-MapDownload($j, [string]$map) {
    Start-Download $j 'map' $map
    Send-Msg $j.Conn 'MAPSTATE' @{ Map = $map; State = 'getting' }
}

function Step-Join($j) {
    if ($j.Done) { return }
    if (-not $j.Conn) {
        if ($j.Bridge -and -not $j.Connecting) {
            if ($j.Bridge.Waiting -and -not $j.SaidWaiting) {
                Say "That address doesn't exist (yet). If the host has only just started the lobby, it takes a minute; still trying..." Yellow
                $j.SaidWaiting = $true
            }
            if ($j.Bridge.Ready) { $j.Connecting = $j.Tcp.ConnectAsync($j.HostName, $j.HostPort) }
            elseif ($j.Bridge.Error -or (Get-Date) -gt $j.Deadline) {
                $why = if ($j.Bridge.Error) { $j.Bridge.Error } else { 'no answer' }
                Say "Couldn't reach the lobby at $($j.Display): $why" Red
                Close-Join $j
            }
        } elseif ($j.Connecting.IsCompleted -and $j.Tcp.Connected) {
            $j.Conn = New-Conn $j.Tcp
            Send-Msg $j.Conn 'HELLO' @{ Name = $Name }
        } elseif ($j.Connecting.IsCompleted -or (Get-Date) -gt $j.Deadline) {
            Say "Couldn't reach the lobby at $($j.Display). Check the address, and that the host's port is open." Red
            Close-Join $j
        }
        return
    }
    foreach ($msg in @(Receive-Msgs $j.Conn)) {
        switch ($msg.Type) {
            'ERROR' { Say $msg.Data.Text Red; $j.Done = $true; return }
            'INFO' { Say $msg.Data.Text Yellow }
            'CHAT' { Say "<$($msg.Data.From)> $($msg.Data.Text)" }
            'STATE' {
                $s = $msg.Data
                $engineDir = Get-EngineDir $s.Engine
                if (-not (Test-Path (Join-Path $engineDir 'spring.exe'))) {
                    Say "The host uses engine $($s.Engine), which isn't in $ZkDir\engine\win64. Start Zero-K normally once so it downloads, or copy that folder from the host." Red
                    $j.Done = $true
                    return
                }
                $script:EngineDir = $engineDir
                $j.State = $s
                Show-Lobby $s
                if ($j.HaveGame -ne $s.Game) {
                    if (-not (Test-GameInstalled $s.Game)) { Start-Download $j 'game' $s.Game }
                    $j.HaveGame = $s.Game
                }
                if ($j.HaveMap -ne $s.Map) {
                    $j.HaveMap = $s.Map
                    if (-not $j.Received[$s.Map] -and -not (Test-MapInstalled $s.Map)) {
                        if ($j.Bridge) {
                            Say "You don't have $($s.Map). Maps can't come through the tunnel, so downloading it from springfiles..." Yellow
                            Start-MapDownload $j $s.Map
                        } else {
                            Say "You don't have $($s.Map); asking the host for it..." Yellow
                            Send-Msg $j.Conn 'NEEDMAP' @{ Map = $s.Map }
                        }
                    }
                }
            }
            'MAPFILE' {
                $file = [IO.Path]::GetFileName([string]$msg.Data.File)  # never trust a path from the network
                if ($file -notmatch '\.(sd7|sdz)$') { Say "Host offered a non-map file '$file'; ignoring." Red; continue }
                $final = Join-Path $ZkDir "maps\$file"
                $j.Dl = [pscustomobject]@{ Map = $msg.Data.Map; Final = $final; Part = "$final.part"; Size = [long]$msg.Data.Size; Got = 0L; NextPct = 10
                    File = [IO.File]::Create("$final.part") }
                Say "Receiving $($j.Dl.Map) ($([Math]::Ceiling($j.Dl.Size / 1MB)) MB)..." Yellow
            }
            'CHUNK' {
                $dl = $j.Dl
                if (-not $dl) { continue }
                $bytes = [Convert]::FromBase64String($msg.Data)
                $dl.File.Write($bytes, 0, $bytes.Length)
                $dl.Got += $bytes.Length
                # the window shows a progress bar instead
                if (-not $script:ui -and $dl.Size -and $dl.Got * 100 / $dl.Size -ge $dl.NextPct) { Say "  $($dl.NextPct)%" DarkGray; $dl.NextPct += 10 }
            }
            'MAPDONE' {
                $dl = $j.Dl
                if (-not $dl) { continue }
                $dl.File.Dispose()
                if ($dl.Got -eq $dl.Size) {
                    Move-Item $dl.Part $dl.Final -Force
                    $j.Received[$dl.Map] = $true
                    Say "Got $($dl.Map)." Green
                } else {
                    Remove-Item $dl.Part -ErrorAction SilentlyContinue
                    Say "Map transfer was incomplete ($($dl.Got) of $($dl.Size) bytes)." Red
                }
                $j.Dl = $null
            }
            'MAPABORT' { Stop-JoinMapDownload $j }
            'NOMAP' {
                Say "The host can't send $($msg.Data.Map); trying to download it from springfiles." Yellow
                Start-MapDownload $j $msg.Data.Map
            }
            'START' {
                foreach ($d in $j.Downloads) { Say "Still downloading $($d.Kind) '$($d.What)'; the game may fail to load." Red }
                Say "Host started the game, launching..." Green
                # The game goes where the lobby connection went: same IP (a tunnel's address may be a hostname) and the
                # same port, not the host's local one, which a tunnel (playit.gg) or router may map to a different public port.
                $ip = $j.Tcp.Client.RemoteEndPoint.Address
                if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
                $gameHost = if ($ip.AddressFamily -eq 'InterNetwork') { $ip.ToString() } else { $j.HostName }
                $j.Game = Start-Spring ("[GAME]`r`n{`r`n  HostIP=$gameHost;`r`n  HostPort=$($j.HostPort);`r`n  IsHost=0;`r`n" +
                    "  MyPlayerName=$Name;`r`n  MyPasswd=$($msg.Data.Password);`r`n}")
            }
        }
    }
    foreach ($d in @($j.Downloads)) {
        if (-not $d.Proc.HasExited) { continue }
        [void]$j.Downloads.Remove($d)
        $ok = $d.Proc.ExitCode -eq 0
        if ($ok) { Say "Downloaded $($d.Kind) '$($d.What)'." Green }
        elseif ($d.Kind -eq 'map') { Say "Couldn't download map '$($d.What)' (not on springfiles, or it's down). You'll stay in the lobby when the game starts; get the map into $ZkDir\maps and rejoin to play." Red }
        else { Say "Couldn't download $($d.Kind) '$($d.What)'. Get it manually or the game will fail to load." Red }
        if ($d.Kind -eq 'map') {
            if ($ok) { $j.Received[$d.What] = $true }
            Send-Msg $j.Conn 'MAPSTATE' @{ Map = $d.What; State = $(if ($ok) { 'ok' } else { 'missing' }) }
        }
    }
    if ($j.Conn.Dead) { Say "The host closed the lobby." Red; $j.Done = $true; return }
    if ($j.Game -and $j.Game.HasExited) {
        $j.Game = $null
        Send-Msg $j.Conn 'BACK' $null
        Say "Back in the lobby." Green
    }
}

function Send-JoinChat($j, [string]$line) {
    if ($j.Conn -and -not $j.Done) { Send-Msg $j.Conn 'CHAT' @{ Text = $line } }
}

function Stop-JoinMapDownload($j) {
    if (-not $j.Dl) { return }
    $j.Dl.File.Dispose()
    Remove-Item $j.Dl.Part -ErrorAction SilentlyContinue
    $j.Dl = $null
}

function Close-Join($j) {
    Stop-JoinMapDownload $j
    $j.Tcp.Close()
    if ($j.Bridge) { $j.Bridge.Close() }
    $j.Done = $true
}

function Start-Join {
    $j = Open-Join $Address
    try {
        while (-not $j.Done) {
            Step-Join $j
            $line = Read-InputLine
            if ($line -eq '/quit') { return }
            if ($line) { Send-JoinChat $j $line }
            Start-Sleep -Milliseconds 50
        }
    } finally { Close-Join $j }
}

# ---------------------------------------------------------------- the window: joining, and hosting via "Host a game..."

$guiColors = @{ Gray = 'Black'; Yellow = 'DarkGoldenrod'; Green = 'ForestGreen'; Red = 'Firebrick'; Cyan = 'Teal'; DarkGray = 'Gray' }

function Initialize-Gui {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    Add-Type -Namespace ZkDirect -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][ZkDirect.Native]::SetProcessDPIAware()  # crisp text on scaled displays; sizes below go through px
    [Windows.Forms.Application]::EnableVisualStyles()
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $script:dpiScale = $g.DpiX / 96
    $g.Dispose()
    $script:uiFont = New-Object Drawing.Font('Segoe UI', 9)
}

function px([double]$n) { [int]($n * $script:dpiScale) }

function New-Control([string]$type, [hashtable]$props = @{}) {
    $c = New-Object "Windows.Forms.$type"
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    $c
}

function New-Grid([int]$columns) {
    New-Control TableLayoutPanel @{ ColumnCount = $columns; AutoSize = $true; Dock = 'Fill'; Margin = 0 }
}

# Zero-K.exe's icon for the windows; $null (keep the default) if the folder has none.
function Get-ZkIcon([string]$dir) {
    if (-not $dir) { return }
    $exe = [IO.Path]::Combine($dir, 'Zero-K.exe')
    if (Test-Path $exe) { [Drawing.Icon]::ExtractAssociatedIcon($exe) }
}

function Set-ZkIcon($form, [string]$dir) {
    $icon = Get-ZkIcon $dir
    if ($icon) { $form.Icon = $icon }
}

function Show-Error([string]$text) {
    [void][Windows.Forms.MessageBox]::Show($text, 'Zero-K Direct', 'OK', 'Error')
}

# ---------------------------------------------------------------- zkjoinbk:// links (per user, no admin needed)

$joinLinkKey = 'HKCU:\Software\Classes\zkjoinbk'

function Get-JoinLinkCommand { "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" gui `"%1`"" }

# The registered command, if zkjoinbk:// links open some copy of zk-direct.
function Get-RegisteredJoinLinks {
    $cmd = (Get-ItemProperty "$joinLinkKey\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
    if ($cmd -like '*zk-direct*') { $cmd }
}

function Register-JoinLinks {
    New-Item "$joinLinkKey\shell\open\command" -Force | Out-Null
    Set-Item $joinLinkKey 'URL:Zero-K Direct join'
    New-ItemProperty $joinLinkKey 'URL Protocol' -Value '' -Force | Out-Null
    Set-Item "$joinLinkKey\shell\open\command" (Get-JoinLinkCommand)
}

function Unregister-JoinLinks {
    if (Get-RegisteredJoinLinks) { Remove-Item $joinLinkKey -Recurse -Force }
}

# Earlier versions registered zkjoin://, which belongs to the Zero-K lobby; hand it back if it still points here.
function Remove-OldJoinLinks {
    $old = 'HKCU:\Software\Classes\zkjoin'
    if ((Get-ItemProperty "$old\shell\open\command" -ErrorAction SilentlyContinue).'(default)' -like '*zk-direct*') { Remove-Item $old -Recurse -Force }
}

# The one-time setup: which Zero-K folder, and your name (defaults to your Zero-K login).
# Returns $true when saved.
function Show-SetupDialog {
    $dir = $ZkDir
    if (-not (Test-ZkDir $dir)) { $dir = Get-DefaultZkDir }
    $savedName = Get-SavedSetting $nameFile
    $st = @{ AutoName = -not $savedName; Filling = $false }
    $linksWere = [bool](Get-RegisteredJoinLinks)

    $form = New-Control Form @{ Text = 'Zero-K Direct: setup'; Font = $script:uiFont; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        StartPosition = 'CenterScreen'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-Object Windows.Forms.Padding (px 12)) }
    Set-ZkIcon $form $dir
    $grid = New-Grid 3
    $intro = New-Control Label @{ AutoSize = $true; MaximumSize = (New-Object Drawing.Size (px 480), 0); Margin = (New-Object Windows.Forms.Padding 0, 0, 0, (px 10))
        Text = 'Choose your Zero-K folder (the one with engine\ inside) and the name other players see. You can change both later under Settings.' }
    $grid.Controls.Add($intro, 0, 0); $grid.SetColumnSpan($intro, 3)
    $grid.Controls.Add((New-Control Label @{ Text = 'Zero-K folder'; AutoSize = $true; Anchor = 'Left' }), 0, 1)
    $txtDir = New-Control TextBox @{ Text = [string]$dir; Width = (px 340) }
    $grid.Controls.Add($txtDir, 1, 1)
    $btnBrowse = New-Control Button @{ Text = 'Browse...'; AutoSize = $true }
    $grid.Controls.Add($btnBrowse, 2, 1)
    $lblDir = New-Control Label @{ AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 3, 0, 3, (px 8)) }
    $grid.Controls.Add($lblDir, 1, 2); $grid.SetColumnSpan($lblDir, 2)
    $grid.Controls.Add((New-Control Label @{ Text = 'Your name'; AutoSize = $true; Anchor = 'Left' }), 0, 3)
    $txtName = New-Control TextBox @{ Text = [string]$savedName; Width = (px 200) }
    $grid.Controls.Add($txtName, 1, 3)
    $lblName = New-Control Label @{ AutoSize = $true; Margin = (New-Object Windows.Forms.Padding 3, 0, 3, (px 8)) }
    $grid.Controls.Add($lblName, 1, 4); $grid.SetColumnSpan($lblName, 2)
    # on by default the first time; afterwards it shows (and changes) whether they're registered
    $chkLinks = New-Control CheckBox @{ Text = 'Register zkjoinbk://... links?'; AutoSize = $true; Checked = ($linksWere -or -not $savedName)
        Margin = (New-Object Windows.Forms.Padding 3, 0, 3, (px 8)) }
    $grid.Controls.Add($chkLinks, 1, 5); $grid.SetColumnSpan($chkLinks, 2)
    $tips = New-Object Windows.Forms.ToolTip -Property @{ ShowAlways = $true }
    $tips.SetToolTip($chkLinks, 'Makes zkjoinbk:// links (e.g. ones players copy from the lobby) open this window and join.')
    $buttons = New-Control FlowLayoutPanel @{ FlowDirection = 'RightToLeft'; AutoSize = $true; Dock = 'Fill'; Margin = 0 }
    $btnOk = New-Control Button @{ Text = 'OK'; DialogResult = 'OK'; Width = (px 80) }
    $btnCancel = New-Control Button @{ Text = 'Cancel'; DialogResult = 'Cancel'; Width = (px 80) }
    $buttons.Controls.AddRange(@($btnCancel, $btnOk))
    $grid.Controls.Add($buttons, 0, 6); $grid.SetColumnSpan($buttons, 3)
    $form.Controls.Add($grid)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $validate = {
        $d = $txtDir.Text.Trim('" ')
        $dirOk = Test-ZkDir $d
        if ($dirOk) {
            $newest = Get-EngineDir -dir $d
            $lblDir.Text = if ($newest) { "Found Zero-K (newest engine: $(Split-Path $newest -Leaf))" } else { 'Found Zero-K, but no engine with spring.exe in it.' }
            $lblDir.ForeColor = 'ForestGreen'
            $login = Get-ZkLoginName $d
            if ($st.AutoName -and $login -and $txtName.Text -ne $login) { $st.Filling = $true; $txtName.Text = $login; $st.Filling = $false }
        } else {
            $lblDir.Text = 'No engine\win64 folder in there.'
            $lblDir.ForeColor = 'Firebrick'
        }
        $nameOk = $txtName.Text.Trim() -match $namePattern
        if (-not $nameOk) { $lblName.Text = 'Letters, digits, _ - [ ] only, up to 30.'; $lblName.ForeColor = 'Firebrick' }
        elseif ($dirOk -and $txtName.Text -eq (Get-ZkLoginName $d)) { $lblName.Text = 'Your Zero-K login name.'; $lblName.ForeColor = 'Gray' }
        else { $lblName.Text = ''; }
        $btnOk.Enabled = $dirOk -and $nameOk
    }
    $txtDir.Add_TextChanged($validate)
    $txtName.Add_TextChanged({ if (-not $st.Filling) { $st.AutoName = $false }; & $validate })
    $btnBrowse.Add_Click({
        $fb = New-Control FolderBrowserDialog @{ Description = 'Your Zero-K folder (the one with engine\ inside)'; ShowNewFolderButton = $false }
        if (Test-Path $txtDir.Text) { $fb.SelectedPath = $txtDir.Text }
        if ($fb.ShowDialog($form) -eq 'OK') { $txtDir.Text = $fb.SelectedPath }
    })
    & $validate

    if ($form.ShowDialog() -ne 'OK') { return $false }
    $script:ZkDir = (Resolve-Path $txtDir.Text.Trim('" ')).Path
    $script:Name = $txtName.Text.Trim()
    Save-Setting $zkDirFile $script:ZkDir
    Save-Setting $nameFile $script:Name
    try { if ($chkLinks.Checked) { Register-JoinLinks } elseif ($linksWere) { Unregister-JoinLinks } }
    catch { Show-Error "Couldn't change the zkjoinbk:// link setting: $($_.Exception.Message)" }
    $true
}

function Write-GuiLog([string]$msg, [string]$color) {
    $box = $script:ui.Log
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = [Drawing.Color]::FromName($guiColors[$color])
    $box.AppendText("$msg`r`n")
    $box.ScrollToCaret()
    $box.Update()  # shows up even while the window is busy, e.g. opening a lobby
}

function Update-GuiLobby($state) {
    $ui = $script:ui
    $ui.Map.Text = "$($state.Map)`n$($state.Game), engine $($state.Engine)"
    $lb = $ui.Lobby
    $lb.BeginUpdate()
    $lb.Items.Clear()
    $teams = @($state.Players | ForEach-Object Team) + @($state.Bots | ForEach-Object Team) | Where-Object { $_ -gt 0 } | Sort-Object -Unique
    foreach ($t in $teams) {
        [void]$lb.Items.Add("Team $t")
        foreach ($p in @($state.Players | Where-Object Team -eq $t)) { [void]$lb.Items.Add("    $(Format-Player $p)") }
        foreach ($b in @($state.Bots | Where-Object Team -eq $t)) { [void]$lb.Items.Add("    $($b.Name) [bot]") }
    }
    $specs = @($state.Players | Where-Object Team -eq 0)
    if ($specs.Count) {
        [void]$lb.Items.Add('Spectators')
        foreach ($p in $specs) { [void]$lb.Items.Add("    $(Format-Player $p)") }
    }
    $lb.EndUpdate()
    $me = $state.Players | Where-Object Name -eq $Name | Select-Object -First 1
    if ($me -and $ui.Team.SelectedIndex -ne [int]$me.Team) {
        $ui.Syncing = $true
        $ui.Team.SelectedIndex = [Math]::Min([int]$me.Team, $ui.Team.Items.Count - 1)
        $ui.Syncing = $false
    }
}

# Enables what fits the connection state and shows progress; called on every timer tick.
function Update-GuiStatus {
    $ui = $script:ui
    $j = $script:join
    $joined = $j -and -not $j.Done
    $hosting = [bool]$script:hosting
    $active = $joined -or $hosting
    $ui.Join.Text = if ($hosting) { 'Stop hosting' } elseif ($joined) { 'Leave' } else { 'Join' }
    $title = if ($hosting) { 'Zero-K Direct (Hosting)' } else { 'Zero-K Direct' }
    if ($ui.Form.Text -ne $title) { $ui.Form.Text = $title }
    $ui.Address.Enabled = -not $active
    $ui.Name.Enabled = -not $active
    $ui.Chat.Enabled = $active
    $ui.Send.Enabled = $active
    $ui.Team.Enabled = $hosting -or ($joined -and $j.State)
    $ui.Progress.Visible = $joined -and $j.Dl
    $ui.HostLink.Enabled = -not $active
    $ui.SettingsLink.Enabled = -not $active
    if ($hosting) {
        $guests = Get-HostGuestCount
        $status = if ($script:hostGame) { 'In game. You come back here when the game closes.' }
            else { "Hosting with $guests other player$(if ($guests -ne 1) { 's' }). Type /start in the chat box to begin, /help for commands." }
    }
    elseif (-not $joined) { $status = 'Not connected. Enter the host''s address and press Join.' }
    elseif (-not $j.Conn) { $status = "Connecting to $($j.Display)..." }
    elseif ($j.Dl) {
        $status = "Receiving $($j.Dl.Map): $([Math]::Round($j.Dl.Got / 1MB)) of $([Math]::Round($j.Dl.Size / 1MB)) MB"
        if ($j.Dl.Size) { $ui.Progress.Value = [Math]::Min(100, [int]($j.Dl.Got * 100 / $j.Dl.Size)) }
    }
    elseif ($j.Downloads.Count) { $status = "Downloading $($j.Downloads[0].Kind) '$($j.Downloads[0].What)'..." }
    elseif ($j.Game) { $status = 'In game. You come back here when the game closes.' }
    else { $status = "In the lobby at $($j.Display). Waiting for the host to start." }
    if ($ui.Status.Text -ne $status) { $ui.Status.Text = $status }

    $link = if ($hosting) { Get-HostInviteLink } elseif ($joined -and $j.State) { Get-InviteLink $j }
    $ui.Invite.Visible = [bool]$link
    if ($link) {
        $text = if ((Get-Date) -lt $ui.CopiedUntil) { 'Copied to the clipboard.' } else { $link }
        if ($ui.Invite.Text -ne $text) { $ui.Invite.Text = $text }
        $ui.Invite.Tag = $link
    }
}

# A zkjoinbk:// link to the lobby you're in, to pass on. A quick tunnel's hostname is enough: joining treats
# *.trycloudflare.com as a tunnel address.
function Get-InviteLink($j) {
    'zkjoinbk://' + ($j.Display -replace '^https://(?=[^/]+\.trycloudflare\.com$)', '')
}

# While hosting: the tunnel's address once it works (none while it's starting), otherwise the public or local one.
function Get-HostInviteLink {
    if ($script:tunnel) {
        if ($script:tunnel.Url) { return 'zkjoinbk://' + ([Uri]$script:tunnel.Url).Host }
        return
    }
    if ($script:hostAddress) { 'zkjoinbk://' + $script:hostAddress }
}

function Copy-InviteLink {
    $link = [string]$script:ui.Invite.Tag
    if (-not $link) { return }
    # the clipboard needs an STA thread, which Windows PowerShell has and PowerShell 7 doesn't
    try { [Windows.Forms.Clipboard]::SetText($link) } catch { Set-Clipboard -Value $link }
    $script:ui.CopiedUntil = (Get-Date).AddSeconds(2)
    Update-GuiStatus
}

function Invoke-GuiJoin {
    $ui = $script:ui
    if ($script:hosting) { [void](Stop-GuiHost); return }  # the button reads 'Stop hosting'
    if ($script:join -and -not $script:join.Done) {
        Close-Join $script:join
        Say 'Left the lobby.' Yellow
        return
    }
    $address = $ui.Address.Text.Trim()
    $n = $ui.Name.Text.Trim()
    if (-not $address) { Show-Error 'Enter the host''s address, like 203.0.113.5, 203.0.113.5:8452 or https://some-words.trycloudflare.com.'; return }
    if ($n -notmatch $namePattern) { Show-Error "Invalid name '$n' (letters, digits, _ - [ ] only, up to 30)."; return }
    $script:Name = $n
    Save-Setting $nameFile $n
    Save-Setting $addressFile $address
    $ui.Lobby.Items.Clear()
    $ui.Map.Text = ''
    $script:join = Open-Join $address
    # Otherwise the Join button keeps focus, and as the focused button it takes Enter: typing a line and pressing Enter would leave.
    Update-GuiStatus
    [void]$ui.Chat.Focus()
}

function Send-GuiChat {
    $line = $script:ui.Chat.Text.Trim()
    $script:ui.Chat.Text = ''
    if ($line -and $script:hosting) {
        if ($line -eq '/quit') { [void](Stop-GuiHost) } else { Invoke-HostCommand $line $script:players[0] }
    } elseif ($line -and $script:join) { Send-JoinChat $script:join $line }
    [void]$script:ui.Chat.Focus()
}

# cloudflared's version, or $null if the file isn't cloudflared; remembered per path, as the dialog asks on every keystroke.
function Get-CloudflaredVersion([string]$path) {
    if (-not $script:cfVersions) { $script:cfVersions = @{} }
    if (-not $script:cfVersions.ContainsKey($path)) {
        $v = $null
        try { if ((& $path --version 2>$null | Out-String) -match 'cloudflared version (\S+)') { $v = $Matches[1] } } catch {}
        $script:cfVersions[$path] = $v
    }
    $script:cfVersions[$path]
}

# Before hosting from the window: how players reach the lobby. Returns $true to go ahead; the choices are remembered.
function Show-HostDialog {
    $cfPath = $null
    try { $cfPath = Find-Cloudflared } catch {}
    $savedTunnel = Get-SavedSetting $hostTunnelFile
    $form = New-Control Form @{ Text = 'Zero-K Direct: host a game'; Font = $script:uiFont; FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false
        StartPosition = 'CenterParent'; AutoSize = $true; AutoSizeMode = 'GrowAndShrink'; Padding = (New-Object Windows.Forms.Padding (px 12)) }
    Set-ZkIcon $form $ZkDir
    $grid = New-Grid 3
    $gap = New-Object Windows.Forms.Padding 3, 0, 3, (px 8)
    $intro = New-Control Label @{ AutoSize = $true; MaximumSize = (New-Object Drawing.Size (px 500), 0); Margin = (New-Object Windows.Forms.Padding 0, 0, 0, (px 10))
        Text = "Players can reach your lobby directly on port $Port (TCP and UDP), through a Cloudflare tunnel, or both. With neither, they need the port forwarded by hand, a VPN, or your local network." }
    $grid.Controls.Add($intro, 0, 0); $grid.SetColumnSpan($intro, 3)
    $chkUpnp = New-Control CheckBox @{ Text = "Ask the router to open port $Port (UPnP)"; AutoSize = $true; Checked = ((Get-SavedSetting $hostUpnpFile) -ne 'off') }
    $grid.Controls.Add($chkUpnp, 0, 1); $grid.SetColumnSpan($chkUpnp, 3)
    $lblUpnp = New-Control Label @{ AutoSize = $true; ForeColor = 'Gray'; Margin = $gap; Text = 'Closed again when the lobby closes. Doesn''t help behind a phone hotspot or a second router.' }
    $grid.Controls.Add($lblUpnp, 0, 2); $grid.SetColumnSpan($lblUpnp, 3)
    $chkTunnel = New-Control CheckBox @{ Text = 'Start a Cloudflare quick tunnel (works without an open port)'; AutoSize = $true
        Checked = $(if ($savedTunnel) { $savedTunnel -eq 'on' } else { [bool]$cfPath }) }
    $grid.Controls.Add($chkTunnel, 0, 3); $grid.SetColumnSpan($chkTunnel, 3)
    $grid.Controls.Add((New-Control Label @{ Text = 'cloudflared.exe'; AutoSize = $true; Anchor = 'Left'; Margin = (New-Object Windows.Forms.Padding (px 18), 0, 3, 0) }), 0, 4)
    $txtCf = New-Control TextBox @{ Text = [string]$cfPath; Width = (px 320) }
    $grid.Controls.Add($txtCf, 1, 4)
    $btnBrowse = New-Control Button @{ Text = 'Browse...'; AutoSize = $true }
    $grid.Controls.Add($btnBrowse, 2, 4)
    $status = New-Control FlowLayoutPanel @{ AutoSize = $true; Margin = $gap; WrapContents = $false }
    $lblCf = New-Control Label @{ AutoSize = $true; Margin = 0 }
    $lnkDownload = New-Control LinkLabel @{ Text = 'download it'; AutoSize = $true; Margin = 0 }
    $status.Controls.AddRange(@($lblCf, $lnkDownload))
    $grid.Controls.Add($status, 1, 5); $grid.SetColumnSpan($status, 2)
    $buttons = New-Control FlowLayoutPanel @{ FlowDirection = 'RightToLeft'; AutoSize = $true; Dock = 'Fill'; Margin = 0 }
    $btnOk = New-Control Button @{ Text = 'Host'; DialogResult = 'OK'; Width = (px 80) }
    $btnCancel = New-Control Button @{ Text = 'Cancel'; DialogResult = 'Cancel'; Width = (px 80) }
    $buttons.Controls.AddRange(@($btnCancel, $btnOk))
    $grid.Controls.Add($buttons, 0, 6); $grid.SetColumnSpan($buttons, 3)
    $form.Controls.Add($grid)
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    $validate = {
        $on = $chkTunnel.Checked
        $txtCf.Enabled = $on
        $btnBrowse.Enabled = $on
        $p = $txtCf.Text.Trim('" ')
        $ok = $true
        $lnkDownload.Visible = $false
        if (-not $on) { $lblCf.Text = '' }
        elseif ($p -and (Test-Path $p -PathType Leaf)) {
            $v = Get-CloudflaredVersion (Resolve-Path $p).Path
            $ok = [bool]$v
            $lblCf.Text = if ($v) { "Found cloudflared $v." } else { 'That file isn''t cloudflared.' }
            $lblCf.ForeColor = if ($v) { 'ForestGreen' } else { 'Firebrick' }
        } else {
            $ok = $false
            $lblCf.Text = 'Choose cloudflared.exe, or'
            $lblCf.ForeColor = 'Firebrick'
            $lnkDownload.Visible = $true
        }
        $btnOk.Enabled = $ok
    }
    $chkTunnel.Add_CheckedChanged($validate)
    $txtCf.Add_TextChanged($validate)
    $btnBrowse.Add_Click({
        $fd = New-Control OpenFileDialog @{ Title = 'Find cloudflared.exe'; Filter = 'cloudflared|cloudflared*.exe|Programs|*.exe'
            InitialDirectory = $(if ($txtCf.Text -and (Test-Path $txtCf.Text)) { Split-Path $txtCf.Text } else { Join-Path $env:USERPROFILE 'Downloads' }) }
        if ($fd.ShowDialog($form) -eq 'OK') { $txtCf.Text = $fd.FileName }
    })
    $lnkDownload.Add_LinkClicked({ Start-Process 'https://github.com/cloudflare/cloudflared/releases/latest' })
    & $validate

    if ($form.ShowDialog($script:ui.Form) -ne 'OK') { return $false }
    $script:NoUpnp = -not $chkUpnp.Checked
    $script:NoTunnel = -not $chkTunnel.Checked
    Save-Setting $hostUpnpFile $(if ($chkUpnp.Checked) { 'on' } else { 'off' })
    Save-Setting $hostTunnelFile $(if ($chkTunnel.Checked) { 'on' } else { 'off' })
    if ($chkTunnel.Checked) {
        $script:Cloudflared = (Resolve-Path $txtCf.Text.Trim('" ')).Path
        Save-Setting $cloudflaredFile $script:Cloudflared
    }
    $true
}

# Hosts from the window: it becomes the host's lobby, with commands typed in the chat box.
function Invoke-GuiHost {
    $ui = $script:ui
    $n = $ui.Name.Text.Trim()
    if ($n -notmatch $namePattern) { Show-Error "Invalid name '$n' (letters, digits, _ - [ ] only, up to 30)."; return }
    if (-not (Show-HostDialog)) { return }
    $script:Name = $n
    Save-Setting $nameFile $n
    $ui.Lobby.Items.Clear()
    $ui.Map.Text = ''
    $script:Mode = 'host'  # names the engine script file
    $script:hosting = $true
    Update-GuiStatus
    $ui.Status.Text = 'Opening the lobby...'
    $ui.Form.Refresh()
    try { Open-Host }
    catch {
        Say "Couldn't open the lobby: $($_.Exception.Message)" Red
        [void](Stop-GuiHost -Force)
        return
    }
    Update-GuiStatus
    [void]$ui.Chat.Focus()
}

# Closes the hosted lobby, first asking if other players are in it. Returns whether it closed.
function Stop-GuiHost([switch]$Force) {
    if (-not $script:hosting) { return $true }
    if (-not $Force -and (Get-HostGuestCount) -gt 0) {
        $answer = [Windows.Forms.MessageBox]::Show($script:ui.Form, 'Other players are connected. This will close the lobby. Are you sure?',
            'Zero-K Direct', 'YesNo', 'Warning', 'Button2')
        if ($answer -ne 'Yes') { return $false }
    }
    try { Close-Host } catch { Say "Error while closing the lobby: $($_.Exception.Message)" Red }
    $script:hosting = $false
    $script:Mode = 'join'
    $script:ui.Lobby.Items.Clear()
    $script:ui.Map.Text = ''
    $script:ui.Syncing = $true
    $script:ui.Team.SelectedIndex = -1
    $script:ui.Syncing = $false
    Say 'Closed the lobby.' Yellow
    Update-GuiStatus
    $true
}

function Start-Gui {
    Initialize-Gui
    $script:Mode = 'join'  # names the engine script file
    $haveSetup = (Test-ZkDir $ZkDir) -or ((Test-ZkDir (Get-SavedSetting $zkDirFile)) -and (Get-SavedSetting $nameFile))
    if ($haveSetup) {
        if (-not (Test-ZkDir $ZkDir)) { $script:ZkDir = Get-SavedSetting $zkDirFile }
        if (-not $Name) { $script:Name = Get-SavedSetting $nameFile }
        if (-not $Name) { $script:Name = Get-ZkLoginName $ZkDir }
    } elseif (-not (Show-SetupDialog)) { return }
    # registered from a folder that has since moved: point the links at this copy
    $registered = Get-RegisteredJoinLinks
    if ($registered -and $registered -ne (Get-JoinLinkCommand)) { try { Register-JoinLinks } catch {} }
    try { Remove-OldJoinLinks } catch {}

    $form = New-Control Form @{ Text = 'Zero-K Direct'; Font = $script:uiFont; StartPosition = 'CenterScreen'
        Size = (New-Object Drawing.Size (px 860), (px 560)); MinimumSize = (New-Object Drawing.Size (px 600), (px 380)) }
    Set-ZkIcon $form $ZkDir
    $root = New-Control TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 4; Padding = (New-Object Windows.Forms.Padding (px 8)) }
    foreach ($style in 'AutoSize', 'Percent', 'AutoSize', 'AutoSize') { [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle $style, 100)) }

    $top = New-Grid 6
    $top.Margin = New-Object Windows.Forms.Padding 0, 0, 0, (px 6)
    $top.Controls.Add((New-Control Label @{ Text = 'Host address'; AutoSize = $true; Anchor = 'Left' }), 0, 0)
    $txtAddress = New-Control TextBox @{ Width = (px 330); Text = $(if ($Address) { $Address -replace '^zkjoin(bk)?://', '' -replace '/+$', '' } else { [string](Get-SavedSetting $addressFile) }) }
    $top.Controls.Add($txtAddress, 1, 0)
    $top.Controls.Add((New-Control Label @{ Text = 'Your name'; AutoSize = $true; Anchor = 'Left'; Margin = (New-Object Windows.Forms.Padding (px 10), 0, 3, 0) }), 2, 0)
    $txtName = New-Control TextBox @{ Width = (px 160); Text = [string]$Name }
    $top.Controls.Add($txtName, 3, 0)
    $btnJoin = New-Control Button @{ Text = 'Join'; Width = (px 90); Margin = (New-Object Windows.Forms.Padding (px 10), 0, 0, 0) }
    $top.Controls.Add($btnJoin, 4, 0)
    $root.Controls.Add($top, 0, 0)

    $split = New-Control SplitContainer @{ Dock = 'Fill'; FixedPanel = 'Panel2' }
    $log = New-Control RichTextBox @{ Dock = 'Fill'; ReadOnly = $true; BackColor = 'White'; DetectUrls = $false; HideSelection = $false }
    $split.Panel1.Controls.Add($log)
    $side = New-Control TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 4; Padding = (New-Object Windows.Forms.Padding (px 6), 0, 0, 0) }
    foreach ($style in 'AutoSize', 'AutoSize', 'Percent', 'AutoSize') { [void]$side.RowStyles.Add((New-Object Windows.Forms.RowStyle $style, 100)) }
    [void]$side.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    [void]$side.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $lblMap = New-Control Label @{ AutoSize = $true; Font = (New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)); Margin = (New-Object Windows.Forms.Padding 0, 0, 0, (px 4)) }
    $side.Controls.Add($lblMap, 0, 0); $side.SetColumnSpan($lblMap, 2)
    # the lobby's zkjoinbk:// link, cut short with ... when it doesn't fit; click to copy
    $lnkInvite = New-Control LinkLabel @{ AutoSize = $false; AutoEllipsis = $true; Dock = 'Fill'; Height = (px 20); Visible = $false
        Margin = (New-Object Windows.Forms.Padding 0, 0, 0, (px 4)) }
    $side.Controls.Add($lnkInvite, 0, 1); $side.SetColumnSpan($lnkInvite, 2)
    $lobby = New-Control ListBox @{ Dock = 'Fill'; IntegralHeight = $false; SelectionMode = 'None' }
    $side.Controls.Add($lobby, 0, 2); $side.SetColumnSpan($lobby, 2)
    $side.Controls.Add((New-Control Label @{ Text = 'Play as'; AutoSize = $true; Anchor = 'Left' }), 0, 3)
    $cmbTeam = New-Control ComboBox @{ DropDownStyle = 'DropDownList'; Dock = 'Fill' }
    [void]$cmbTeam.Items.Add('Spectator')
    foreach ($t in 1..16) { [void]$cmbTeam.Items.Add("Team $t") }
    $side.Controls.Add($cmbTeam, 1, 3)
    $split.Panel2.Controls.Add($side)
    $root.Controls.Add($split, 0, 1)

    $chatRow = New-Grid 2
    [void]$chatRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    [void]$chatRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    $chatRow.Margin = New-Object Windows.Forms.Padding 0, (px 6), 0, (px 4)
    $txtChat = New-Control TextBox @{ Dock = 'Fill' }
    $chatRow.Controls.Add($txtChat, 0, 0)
    $btnSend = New-Control Button @{ Text = 'Send'; Width = (px 90) }
    $chatRow.Controls.Add($btnSend, 1, 0)
    $root.Controls.Add($chatRow, 0, 2)

    $bottom = New-Grid 4
    [void]$bottom.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $lblStatus = New-Control Label @{ AutoSize = $true; Anchor = 'Left'; ForeColor = 'DimGray' }
    $bottom.Controls.Add($lblStatus, 0, 0)
    $progress = New-Control ProgressBar @{ Width = (px 160); Height = (px 14); Anchor = 'Right'; Visible = $false }
    $bottom.Controls.Add($progress, 1, 0)
    $lnkHost = New-Control LinkLabel @{ Text = 'Host a game...'; AutoSize = $true; Anchor = 'Right'; Margin = (New-Object Windows.Forms.Padding (px 12), 0, 0, 0) }
    $bottom.Controls.Add($lnkHost, 2, 0)
    $lnkSettings = New-Control LinkLabel @{ Text = 'Settings...'; AutoSize = $true; Anchor = 'Right'; Margin = (New-Object Windows.Forms.Padding (px 12), 0, 0, 0) }
    $bottom.Controls.Add($lnkSettings, 3, 0)
    $root.Controls.Add($bottom, 0, 3)
    $form.Controls.Add($root)

    $script:ui = [pscustomobject]@{ Form = $form; Address = $txtAddress; Name = $txtName; Join = $btnJoin; Log = $log; Map = $lblMap; Lobby = $lobby
        Team = $cmbTeam; Chat = $txtChat; Send = $btnSend; Status = $lblStatus; Progress = $progress; Syncing = $false
        Invite = $lnkInvite; Tips = (New-Object Windows.Forms.ToolTip -Property @{ ShowAlways = $true }); CopiedUntil = [datetime]::MinValue
        HostLink = $lnkHost; SettingsLink = $lnkSettings }
    $script:ui.Tips.SetToolTip($lnkInvite, 'Copy join URL to clipboard')
    $script:join = $null
    $script:hosting = $false

    # Event handlers: errors go to the log rather than a stack of dialogs.
    $guard = { param($action) try { & $action } catch { Say "Error: $($_.Exception.Message)" Red } }
    $btnJoin.Add_Click({ & $guard { Invoke-GuiJoin; Update-GuiStatus } })
    $txtAddress.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $guard { Invoke-GuiJoin } } })
    $txtName.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $guard { Invoke-GuiJoin } } })
    $btnSend.Add_Click({ & $guard { Send-GuiChat } })
    $txtChat.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $guard { Send-GuiChat } } })
    $cmbTeam.Add_SelectedIndexChanged({
        if ($script:ui.Syncing) { return }
        $i = $script:ui.Team.SelectedIndex
        $cmd = if ($i -eq 0) { '/spec' } else { "/team $i" }
        if ($script:hosting) { & $guard { Invoke-HostCommand $cmd $script:players[0] } }
        elseif ($script:join) { & $guard { Send-JoinChat $script:join $cmd } }
    })
    $lnkHost.Add_LinkClicked({ & $guard { Invoke-GuiHost } })
    $lnkInvite.Add_LinkClicked({ & $guard { Copy-InviteLink } })
    $lnkSettings.Add_LinkClicked({
        if ($script:join -and -not $script:join.Done) { Show-Error 'Leave the lobby first.'; return }
        & $guard {
            if (Show-SetupDialog) {
                $script:ui.Name.Text = $Name
                Set-ZkIcon $script:ui.Form $ZkDir
                Install-Bundle
                $script:EngineDir = Get-EngineDir $Engine
                Say "Zero-K folder: $ZkDir" DarkGray
            }
        }
    })

    $timer = New-Control Timer @{ Interval = 50 }
    $timer.Add_Tick({
        $j = $script:join
        if ($j -and -not $j.Done) {
            try { Step-Join $j } catch { Say "Error: $($_.Exception.Message)" Red; Close-Join $j }
        }
        if ($script:hosting) {
            try {
                Step-Host
                if ($script:quit) { [void](Stop-GuiHost -Force) }
            } catch { Say "Error: $($_.Exception.Message)" Red; [void](Stop-GuiHost -Force) }
        }
        Update-GuiStatus
    })
    $form.Add_Shown({
        $split.SplitterDistance = [Math]::Max((px 200), $split.Width - (px 250))
        Update-GuiStatus
        Say "Zero-K folder: $ZkDir" DarkGray
        $script:ui.Status.Text = 'Checking the install...'
        $form.Refresh()
        & $guard { Install-Bundle }
        $script:EngineDir = Get-EngineDir $Engine
        if (-not $script:EngineDir) { Say "No engine in $ZkDir\engine\win64. Use Settings to pick another folder." Red }
        $timer.Start()
        if ($Address) { & $guard { Invoke-GuiJoin } }
        elseif ($txtAddress.Text) { $txtName.Focus() } else { $txtAddress.Focus() }
    })
    $form.Add_FormClosing({
        $e = $_
        if ($script:hosting -and -not (Stop-GuiHost)) { $e.Cancel = $true; return }
        $timer.Stop()
        if ($script:join -and -not $script:join.Done) { Close-Join $script:join }
    })
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------- main

if ($Mode -eq 'install') {
    Register-JoinLinks
    Remove-OldJoinLinks
    Write-Host "zkjoinbk:// links now open the join window." -ForegroundColor Green
    return
}

if (-not $Mode -or $Mode -eq 'gui') {
    try { Start-Gui }
    catch {
        $msg = "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)"
        try { Show-Error $msg } catch { Write-Host $msg -ForegroundColor Red }
    }
    return
}

try {
    if ($Mode -notin 'host', 'join') { throw "Mode must be 'host', 'join', 'gui' or 'install' (or nothing, for the join window)." }
    $ZkDir = Find-ZkDir
    Install-Bundle
    if ($Mode -eq 'join' -and -not $Address) { $Address = Read-Host 'Host address (ip or ip:port)' }
    if (-not $Name) { $Name = Get-SavedSetting $nameFile }
    if (-not $Name) { $Name = Get-ZkLoginName $ZkDir }
    if (-not $Name) { $Name = Read-Host 'Your name' }
    if ($Name -notmatch $namePattern) { throw "Invalid name '$Name' (letters, digits, _ - [ ] only)." }
    Save-Setting $nameFile $Name

    $script:EngineDir = Get-EngineDir $Engine
    if (-not (Test-Path (Join-Path $script:EngineDir 'spring.exe'))) { throw "No spring.exe in '$($script:EngineDir)'." }

    if ($Mode -eq 'host') { Start-Host } else { Start-Join }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    if (-not $env:ZK_DIRECT_NOPAUSE) { Read-Host 'Press Enter to close' | Out-Null }
}
