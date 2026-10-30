<#
.SYNOPSIS
Direct-IP Zero-K multiplayer without the Zero-K lobby server.

.DESCRIPTION
The host runs a tiny text lobby (TCP) where players gather, chat and pick teams.
When the host types /start, everyone's engine is launched with a generated script
and connects straight to the host's game (UDP, same port number).

  Join:    zk-direct.cmd                      (no arguments: a window for joining)
           zk-direct.cmd join 203.0.113.5 -Name Bob   (the same in the terminal)
  Host:    zk-direct.cmd host -Name Tom [-Map "TitanDuel 2.2"] [-Port 8452]
  Link:    zk-direct.cmd install   (once; then zkjoin://203.0.113.5:8452 links open the join window)

The host must be reachable on -Port over BOTH TCP and UDP: forward it on the router,
or have everyone join the same VPN (Tailscale, ZeroTier, Radmin VPN) and use that IP.

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
    [Alias('ZkPath')][string]$ZkDir
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$scriptPath = $MyInvocation.MyCommand.Path
$scriptDir = Split-Path -Parent $scriptPath
$configDir = Join-Path $env:LOCALAPPDATA 'zk-direct'
$nameFile = Join-Path $configDir 'name.txt'
$zkDirFile = Join-Path $configDir 'zkdir.txt'
$addressFile = Join-Path $configDir 'address.txt'
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
    if (-not (Test-Path $path)) { Write-Note "No bundle\$name; download it from the repo's Releases page into bundle\ to have it installed."; return }
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
    [pscustomobject]@{ Tcp = $tcp; Stream = $tcp.GetStream(); Decoder = $utf8.GetDecoder(); Buf = [Text.StringBuilder]::new(); Dead = $false; Player = $null; Transfer = $null }
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
        Players = @($script:players | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Team = $_.Team; InGame = $_.InGame; Downloading = $_.Downloading } })
        Bots    = @($script:bots | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Team = $_.Team; Ai = $_.Ai } })
    }
}

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

function Build-HostScript {
    $me = $script:players[0]
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
    for ($i = 0; $i -lt $script:players.Count; $i++) {
        $p = $script:players[$i]
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
Players missing the map get it from you automatically.
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
    if ($busy.Count) { Say "Still getting the map: $($busy -join ', '). Wait for them, or /spec or /kick them." Red; return }
    if (-not (@($script:players | Where-Object Team -gt 0).Count + $script:bots.Count)) { Say "Nobody is on a team." Red; return }
    $hostScript = Build-HostScript
    foreach ($c in $script:conns) { if ($c.Player) { Send-Msg $c 'START' @{ Port = $Port; Password = $c.Player.Password }; $c.Player.InGame = $true } }
    Send-Info "Starting the game..."
    $script:players[0].InGame = $true
    $script:hostGame = Start-Spring $hostScript
}

function Show-JoinInfo {
    $ips = @()
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object IPAddress
    } catch {}
    $public = $null
    try { $public = (Invoke-RestMethod 'https://api.ipify.org' -TimeoutSec 3).ToString().Trim() } catch {}
    Say "Lobby open on TCP+UDP port $Port. Friends double-click zk-direct.cmd and join one of:" Green
    if ($public) { Say "    ${public}:$Port      (internet: needs port $Port TCP+UDP forwarded to this PC)" Green }
    foreach ($ip in $ips) { Say "    ${ip}:$Port" Green }
    Say "  (or 'zk-direct.cmd join <address>' in a terminal, or a zkjoin://<address> link). Type /help for commands." Green
}

function Start-Host {
    $script:EngineName = Split-Path $script:EngineDir -Leaf
    $script:GameName = Resolve-GameName $Game
    $script:MapName = $Map
    Confirm-Content $script:GameName $script:MapName

    $script:players = [Collections.Generic.List[object]]::new()
    $script:bots = [Collections.Generic.List[object]]::new()
    $script:conns = [Collections.Generic.List[object]]::new()
    $script:quit = $false
    $script:hostGame = $null
    $script:players.Add([pscustomobject]@{ Name = $Name; Team = 1; Password = (New-Password); InGame = $false; Downloading = $false })

    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
    $listener.Start()
    try {
        Show-JoinInfo
        Publish-State
        while (-not $script:quit) {
            while ($listener.Pending()) { $script:conns.Add((New-Conn $listener.AcceptTcpClient())) }

            foreach ($c in @($script:conns)) {
                foreach ($msg in @(Receive-Msgs $c)) {
                    if ($msg.Type -eq 'HELLO' -and -not $c.Player) {
                        $n = [string]$msg.Data.Name
                        if ($n -notmatch $namePattern) { Send-Msg $c 'ERROR' @{ Text = "Invalid name '$n' (letters, digits, _ - [ ] only)." }; $c.Dead = $true }
                        elseif (Find-Member $n) { Send-Msg $c 'ERROR' @{ Text = "The name '$n' is taken." }; $c.Dead = $true }
                        else {
                            $c.Player = [pscustomobject]@{ Name = $n; Team = (Get-DefaultTeam); Password = (New-Password); InGame = $false; Downloading = $false }
                            $script:players.Add($c.Player)
                            Send-Info "$n joined."
                            Publish-State
                        }
                    } elseif ($msg.Type -eq 'CHAT' -and $c.Player) {
                        Invoke-HostCommand ([string]$msg.Data.Text) $c.Player
                    } elseif ($msg.Type -eq 'BACK' -and $c.Player) {
                        $c.Player.InGame = $false
                        Send-Info "$($c.Player.Name) is back in the lobby."
                        Publish-State
                    } elseif ($msg.Type -eq 'NEEDMAP' -and $c.Player) {
                        Start-MapSend $c ([string]$msg.Data.Map)
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

            $line = Read-InputLine
            if ($line) { Invoke-HostCommand $line $script:players[0] }

            if ($script:hostGame -and $script:hostGame.HasExited) {
                $script:hostGame = $null
                $script:players[0].InGame = $false
                Send-Info "$($script:players[0].Name) (host) is back in the lobby."
                Publish-State
            }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        foreach ($c in $script:conns) { Stop-MapSend $c; $c.Tcp.Close() }
        $listener.Stop()
    }
}

# ---------------------------------------------------------------- join

# A join session; Step-Join advances it without blocking, from the terminal loop or the window's timer.
function Open-Join([string]$address) {
    $addr = $address.Trim() -replace '^zkjoin://', '' -replace '/+$', ''
    $hostName = $addr
    $hostPort = $Port
    if ($addr -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $hostPort = [int]$Matches[2] }
    Say "Connecting to ${hostName}:$hostPort..." Yellow
    $tcp = New-Object Net.Sockets.TcpClient
    [pscustomobject]@{
        HostName = $hostName; HostPort = $hostPort; Tcp = $tcp; Conn = $null; Done = $false
        Connecting = $tcp.ConnectAsync($hostName, $hostPort); Deadline = (Get-Date).AddSeconds(10)
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

function Step-Join($j) {
    if ($j.Done) { return }
    if (-not $j.Conn) {
        if ($j.Connecting.IsCompleted -and $j.Tcp.Connected) {
            $j.Conn = New-Conn $j.Tcp
            Send-Msg $j.Conn 'HELLO' @{ Name = $Name }
        } elseif ($j.Connecting.IsCompleted -or (Get-Date) -gt $j.Deadline) {
            Say "Couldn't reach the lobby at $($j.HostName):$($j.HostPort). Check the address, and that the host's port is open." Red
            $j.Done = $true
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
                        Say "You don't have $($s.Map); asking the host for it..." Yellow
                        Send-Msg $j.Conn 'NEEDMAP' @{ Map = $s.Map }
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
                Say "The host can't send $($msg.Data.Map) either; trying to download it." Yellow
                Start-Download $j 'map' $msg.Data.Map
            }
            'START' {
                foreach ($d in $j.Downloads) { Say "Still downloading $($d.Kind) '$($d.What)'; the game may fail to load." Red }
                Say "Host started the game, launching..." Green
                $j.Game = Start-Spring ("[GAME]`r`n{`r`n  HostIP=$($j.HostName);`r`n  HostPort=$($msg.Data.Port);`r`n  IsHost=0;`r`n" +
                    "  MyPlayerName=$Name;`r`n  MyPasswd=$($msg.Data.Password);`r`n}")
            }
        }
    }
    foreach ($d in @($j.Downloads)) {
        if (-not $d.Proc.HasExited) { continue }
        [void]$j.Downloads.Remove($d)
        if ($d.Proc.ExitCode -eq 0) { Say "Downloaded $($d.Kind) '$($d.What)'." Green }
        else { Say "Couldn't download $($d.Kind) '$($d.What)'. Get it manually or the game will fail to load." Red }
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

# ---------------------------------------------------------------- join window (hosting stays in the terminal)

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

# The one-time setup: which Zero-K folder, and your name (defaults to your Zero-K login).
# Returns $true when saved.
function Show-SetupDialog {
    $dir = $ZkDir
    if (-not (Test-ZkDir $dir)) { $dir = Get-DefaultZkDir }
    $savedName = Get-SavedSetting $nameFile
    $st = @{ AutoName = -not $savedName; Filling = $false }

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
    $buttons = New-Control FlowLayoutPanel @{ FlowDirection = 'RightToLeft'; AutoSize = $true; Dock = 'Fill'; Margin = 0 }
    $btnOk = New-Control Button @{ Text = 'OK'; DialogResult = 'OK'; Width = (px 80) }
    $btnCancel = New-Control Button @{ Text = 'Cancel'; DialogResult = 'Cancel'; Width = (px 80) }
    $buttons.Controls.AddRange(@($btnCancel, $btnOk))
    $grid.Controls.Add($buttons, 0, 5); $grid.SetColumnSpan($buttons, 3)
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
    $true
}

function Write-GuiLog([string]$msg, [string]$color) {
    $box = $script:ui.Log
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = [Drawing.Color]::FromName($guiColors[$color])
    $box.AppendText("$msg`r`n")
    $box.ScrollToCaret()
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
    $active = $j -and -not $j.Done
    $ui.Join.Text = if ($active) { 'Leave' } else { 'Join' }
    $ui.Address.Enabled = -not $active
    $ui.Name.Enabled = -not $active
    $ui.Chat.Enabled = $active
    $ui.Send.Enabled = $active
    $ui.Team.Enabled = $active -and $j.State
    $ui.Progress.Visible = $active -and $j.Dl
    if (-not $active) { $status = 'Not connected. Enter the host''s address and press Join.' }
    elseif (-not $j.Conn) { $status = "Connecting to $($j.HostName):$($j.HostPort)..." }
    elseif ($j.Dl) {
        $status = "Receiving $($j.Dl.Map): $([Math]::Round($j.Dl.Got / 1MB)) of $([Math]::Round($j.Dl.Size / 1MB)) MB"
        if ($j.Dl.Size) { $ui.Progress.Value = [Math]::Min(100, [int]($j.Dl.Got * 100 / $j.Dl.Size)) }
    }
    elseif ($j.Downloads.Count) { $status = "Downloading $($j.Downloads[0].Kind) '$($j.Downloads[0].What)'..." }
    elseif ($j.Game) { $status = 'In game. You come back here when the game closes.' }
    else { $status = "In the lobby at $($j.HostName):$($j.HostPort). Waiting for the host to start." }
    if ($ui.Status.Text -ne $status) { $ui.Status.Text = $status }
}

function Invoke-GuiJoin {
    $ui = $script:ui
    if ($script:join -and -not $script:join.Done) {
        Close-Join $script:join
        Say 'Left the lobby.' Yellow
        return
    }
    $address = $ui.Address.Text.Trim()
    $n = $ui.Name.Text.Trim()
    if (-not $address) { Show-Error 'Enter the host''s address, like 203.0.113.5 or 203.0.113.5:8452.'; return }
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
    if ($line -and $script:join) { Send-JoinChat $script:join $line }
    [void]$script:ui.Chat.Focus()
}

function Start-HostTerminal {
    $hostArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"", 'host', '-ZkPath', "`"$ZkDir`"")
    $n = $script:ui.Name.Text.Trim()
    if ($n -match $namePattern) { $hostArgs += '-Name', $n }
    Start-Process powershell.exe -ArgumentList $hostArgs
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

    $form = New-Control Form @{ Text = 'Zero-K Direct'; Font = $script:uiFont; StartPosition = 'CenterScreen'
        Size = (New-Object Drawing.Size (px 860), (px 560)); MinimumSize = (New-Object Drawing.Size (px 600), (px 380)) }
    Set-ZkIcon $form $ZkDir
    $root = New-Control TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 1; RowCount = 4; Padding = (New-Object Windows.Forms.Padding (px 8)) }
    foreach ($style in 'AutoSize', 'Percent', 'AutoSize', 'AutoSize') { [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle $style, 100)) }

    $top = New-Grid 6
    $top.Margin = New-Object Windows.Forms.Padding 0, 0, 0, (px 6)
    $top.Controls.Add((New-Control Label @{ Text = 'Host address'; AutoSize = $true; Anchor = 'Left' }), 0, 0)
    $txtAddress = New-Control TextBox @{ Width = (px 220); Text = $(if ($Address) { $Address -replace '^zkjoin://', '' -replace '/+$', '' } else { [string](Get-SavedSetting $addressFile) }) }
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
    $side = New-Control TableLayoutPanel @{ Dock = 'Fill'; ColumnCount = 2; RowCount = 3; Padding = (New-Object Windows.Forms.Padding (px 6), 0, 0, 0) }
    foreach ($style in 'AutoSize', 'Percent', 'AutoSize') { [void]$side.RowStyles.Add((New-Object Windows.Forms.RowStyle $style, 100)) }
    [void]$side.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'AutoSize'))
    [void]$side.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle 'Percent', 100))
    $lblMap = New-Control Label @{ AutoSize = $true; Font = (New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)); Margin = (New-Object Windows.Forms.Padding 0, 0, 0, (px 4)) }
    $side.Controls.Add($lblMap, 0, 0); $side.SetColumnSpan($lblMap, 2)
    $lobby = New-Control ListBox @{ Dock = 'Fill'; IntegralHeight = $false; SelectionMode = 'None' }
    $side.Controls.Add($lobby, 0, 1); $side.SetColumnSpan($lobby, 2)
    $side.Controls.Add((New-Control Label @{ Text = 'Play as'; AutoSize = $true; Anchor = 'Left' }), 0, 2)
    $cmbTeam = New-Control ComboBox @{ DropDownStyle = 'DropDownList'; Dock = 'Fill' }
    [void]$cmbTeam.Items.Add('Spectator')
    foreach ($t in 1..16) { [void]$cmbTeam.Items.Add("Team $t") }
    $side.Controls.Add($cmbTeam, 1, 2)
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
        Team = $cmbTeam; Chat = $txtChat; Send = $btnSend; Status = $lblStatus; Progress = $progress; Syncing = $false }
    $script:join = $null

    # Event handlers: errors go to the log rather than a stack of dialogs.
    $guard = { param($action) try { & $action } catch { Say "Error: $($_.Exception.Message)" Red } }
    $btnJoin.Add_Click({ & $guard { Invoke-GuiJoin; Update-GuiStatus } })
    $txtAddress.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $guard { Invoke-GuiJoin } } })
    $txtName.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $guard { Invoke-GuiJoin } } })
    $btnSend.Add_Click({ & $guard { Send-GuiChat } })
    $txtChat.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; & $guard { Send-GuiChat } } })
    $cmbTeam.Add_SelectedIndexChanged({
        if ($script:ui.Syncing -or -not $script:join) { return }
        $i = $script:ui.Team.SelectedIndex
        & $guard { Send-JoinChat $script:join $(if ($i -eq 0) { '/spec' } else { "/team $i" }) }
    })
    $lnkHost.Add_LinkClicked({ & $guard { Start-HostTerminal } })
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
        $timer.Stop()
        if ($script:join -and -not $script:join.Done) { Close-Join $script:join }
    })
    [void]$form.ShowDialog()
}

# ---------------------------------------------------------------- main

if ($Mode -eq 'install') {
    $key = 'HKCU:\Software\Classes\zkjoin'
    New-Item "$key\shell\open\command" -Force | Out-Null
    Set-Item $key 'URL:Zero-K direct join'
    New-ItemProperty $key 'URL Protocol' -Value '' -Force | Out-Null
    Set-Item "$key\shell\open\command" "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" gui `"%1`""
    Write-Host "zkjoin:// links now open the join window." -ForegroundColor Green
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
