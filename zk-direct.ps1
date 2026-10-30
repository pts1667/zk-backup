<#
.SYNOPSIS
Direct-IP Zero-K multiplayer without the Zero-K lobby server.

.DESCRIPTION
The host runs a tiny text lobby (TCP) where players gather, chat and pick teams.
When the host types /start, everyone's engine is launched with a generated script
and connects straight to the host's game (UDP, same port number).

  Host:    zk-direct.cmd host -Name Tom [-Map "TitanDuel 2.2"] [-Port 8452]
  Join:    zk-direct.cmd join 203.0.113.5 -Name Bob
  Link:    zk-direct.cmd install   (once; then zkjoin://203.0.113.5:8452 links open the join flow)

The host must be reachable on -Port over BOTH TCP and UDP: forward it on the router,
or have everyone join the same VPN (Tailscale, ZeroTier, Radmin VPN) and use that IP.

The Zero-K folder (the one containing engine\) is found from, in order: -ZkDir (alias -ZkPath),
the ZK_DIR environment variable, the last folder used, this script's folder, Steam libraries;
otherwise you're asked once. The choice is remembered in %LOCALAPPDATA%\zk-direct.
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
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configDir = Join-Path $env:LOCALAPPDATA 'zk-direct'
$nameFile = Join-Path $configDir 'name.txt'
$zkDirFile = Join-Path $configDir 'zkdir.txt'
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

function Find-ZkDir {
    $candidates = @($ZkDir, $env:ZK_DIR)
    if (Test-Path $zkDirFile) { $candidates += (Get-Content $zkDirFile -Raw).Trim() }
    $candidates += $scriptDir
    $candidates += Get-SteamZkDirs
    $found = $candidates | Where-Object { Test-ZkDir $_ } | Select-Object -First 1
    if ($ZkDir -and $found -ne $ZkDir) { throw "'$ZkDir' isn't a Zero-K folder (no engine\win64 inside)." }
    while (-not $found) {
        $answer = (Read-Host 'Path to your Zero-K folder (the one containing engine\)').Trim('" ')
        if (Test-ZkDir $answer) { $found = $answer } else { Write-Host "No engine\win64 in '$answer'." -ForegroundColor Red }
    }
    $found = (Resolve-Path $found).Path
    [void](New-Item $configDir -ItemType Directory -Force)
    [IO.File]::WriteAllText($zkDirFile, $found, $utf8)
    $found
}

function Get-EngineDir([string]$version) {
    $root = Join-Path $ZkDir 'engine\win64'
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
    if (-not (Test-Path $path)) { Write-Host "No bundle\$name; download it from the repo's Releases page into bundle\ to have it installed." -ForegroundColor Yellow; return }
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
            Write-Host "Installing bundled engine $($bundle.Engine)..." -ForegroundColor Yellow
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $engineDir)
        }
    }
    if (-not (Test-GameInstalled $bundle.Game)) {
        $archive = Get-BundleFile $bundle.GameArchive
        if ($archive) {
            Write-Host "Installing bundled $($bundle.Game)..." -ForegroundColor Yellow
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
    $width = 80
    try { $width = [Console]::WindowWidth } catch {}
    [Console]::Write("`r" + (' ' * ($width - 1)) + "`r")
    Write-Host $msg -ForegroundColor $color
    Show-Prompt
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
    Say "Lobby open on TCP+UDP port $Port. Friends join with one of:" Green
    if ($public) { Say "    zk-direct.cmd join ${public}:$Port      (internet: needs port $Port TCP+UDP forwarded to this PC)" Green }
    foreach ($ip in $ips) { Say "    zk-direct.cmd join ${ip}:$Port" Green }
    Say "  or a zkjoin://<ip>:$Port link if they ran 'zk-direct.cmd install'. Type /help for commands." Green
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
                        if ($n -notmatch '^[A-Za-z0-9_\-\[\]]{1,30}$') { Send-Msg $c 'ERROR' @{ Text = "Invalid name '$n' (letters, digits, _ - [ ] only)." }; $c.Dead = $true }
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

function Start-Join {
    $addr = $Address -replace '^zkjoin://', '' -replace '/+$', ''
    $hostName = $addr
    $hostPort = $Port
    if ($addr -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $hostPort = [int]$Matches[2] }

    Say "Connecting to ${hostName}:$hostPort..." Yellow
    $tcp = New-Object Net.Sockets.TcpClient
    if (-not $tcp.ConnectAsync($hostName, $hostPort).Wait(10000)) { throw "Couldn't reach the lobby at ${hostName}:$hostPort." }
    $conn = New-Conn $tcp
    Send-Msg $conn 'HELLO' @{ Name = $Name }
    $have = @{ Game = $null; Map = $null }
    $received = @{}  # maps received this session; the engine's cache doesn't know them until it rescans
    $dl = $null
    $game = $null
    try {
        while ($true) {
            foreach ($msg in @(Receive-Msgs $conn)) {
                switch ($msg.Type) {
                    'ERROR' { Say $msg.Data.Text Red; return }
                    'INFO' { Say $msg.Data.Text Yellow }
                    'CHAT' { Say "<$($msg.Data.From)> $($msg.Data.Text)" }
                    'STATE' {
                        $s = $msg.Data
                        $engineDir = Get-EngineDir $s.Engine
                        if (-not (Test-Path (Join-Path $engineDir 'spring.exe'))) {
                            Say "The host uses engine $($s.Engine), which isn't in $ZkDir\engine\win64. Start Zero-K normally once so it downloads, or copy that folder from the host." Red
                            return
                        }
                        $script:EngineDir = $engineDir
                        Show-Lobby $s
                        if ($have.Game -ne $s.Game) {
                            if (-not (Test-GameInstalled $s.Game)) { Invoke-Download 'game' $s.Game }
                            $have.Game = $s.Game
                        }
                        if ($have.Map -ne $s.Map) {
                            $have.Map = $s.Map
                            if (-not $received[$s.Map] -and -not (Test-MapInstalled $s.Map)) {
                                Say "You don't have $($s.Map); asking the host for it..." Yellow
                                Send-Msg $conn 'NEEDMAP' @{ Map = $s.Map }
                            }
                        }
                    }
                    'MAPFILE' {
                        $file = [IO.Path]::GetFileName([string]$msg.Data.File)  # never trust a path from the network
                        if ($file -notmatch '\.(sd7|sdz)$') { Say "Host offered a non-map file '$file'; ignoring." Red; continue }
                        $final = Join-Path $ZkDir "maps\$file"
                        $dl = [pscustomobject]@{ Map = $msg.Data.Map; Final = $final; Part = "$final.part"; Size = [long]$msg.Data.Size; Got = 0L; NextPct = 10
                            File = [IO.File]::Create("$final.part") }
                        Say "Receiving $($dl.Map) ($([Math]::Ceiling($dl.Size / 1MB)) MB)..." Yellow
                    }
                    'CHUNK' {
                        if (-not $dl) { continue }
                        $bytes = [Convert]::FromBase64String($msg.Data)
                        $dl.File.Write($bytes, 0, $bytes.Length)
                        $dl.Got += $bytes.Length
                        if ($dl.Size -and $dl.Got * 100 / $dl.Size -ge $dl.NextPct) { Say "  $($dl.NextPct)%" DarkGray; $dl.NextPct += 10 }
                    }
                    'MAPDONE' {
                        if (-not $dl) { continue }
                        $dl.File.Dispose()
                        if ($dl.Got -eq $dl.Size) {
                            Move-Item $dl.Part $dl.Final -Force
                            $received[$dl.Map] = $true
                            Say "Got $($dl.Map)." Green
                        } else {
                            Remove-Item $dl.Part -ErrorAction SilentlyContinue
                            Say "Map transfer was incomplete ($($dl.Got) of $($dl.Size) bytes)." Red
                        }
                        $dl = $null
                    }
                    'MAPABORT' {
                        if ($dl) { $dl.File.Dispose(); Remove-Item $dl.Part -ErrorAction SilentlyContinue; $dl = $null }
                    }
                    'NOMAP' {
                        Say "The host can't send $($msg.Data.Map) either; trying to download it." Yellow
                        Invoke-Download 'map' $msg.Data.Map
                    }
                    'START' {
                        Say "Host started the game, launching..." Green
                        $game = Start-Spring ("[GAME]`r`n{`r`n  HostIP=$hostName;`r`n  HostPort=$($msg.Data.Port);`r`n  IsHost=0;`r`n" +
                            "  MyPlayerName=$Name;`r`n  MyPasswd=$($msg.Data.Password);`r`n}")
                    }
                }
            }
            if ($conn.Dead) { Say "The host closed the lobby." Red; return }
            if ($game -and $game.HasExited) {
                $game = $null
                Send-Msg $conn 'BACK' $null
                Say "Back in the lobby." Green
            }
            $line = Read-InputLine
            if ($line -eq '/quit') { return }
            if ($line) { Send-Msg $conn 'CHAT' @{ Text = $line } }
            Start-Sleep -Milliseconds 50
        }
    } finally {
        if ($dl) { $dl.File.Dispose(); Remove-Item $dl.Part -ErrorAction SilentlyContinue }
        $tcp.Close()
    }
}

# ---------------------------------------------------------------- main

if ($Mode -eq 'install') {
    $key = 'HKCU:\Software\Classes\zkjoin'
    New-Item "$key\shell\open\command" -Force | Out-Null
    Set-Item $key 'URL:Zero-K direct join'
    New-ItemProperty $key 'URL Protocol' -Value '' -Force | Out-Null
    Set-Item "$key\shell\open\command" "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" join `"%1`""
    Write-Host "zkjoin:// links now open $PSCommandPath." -ForegroundColor Green
    return
}

try {
    $ZkDir = Find-ZkDir
    Install-Bundle
    if (-not $Mode) { $Mode = Read-Host 'host or join' }
    if ($Mode -notin 'host', 'join') { throw "Mode must be 'host', 'join' or 'install'." }
    if ($Mode -eq 'join' -and -not $Address) { $Address = Read-Host 'Host address (ip or ip:port)' }
    if (-not $Name -and (Test-Path $nameFile)) { $Name = (Get-Content $nameFile -Raw).Trim() }
    if (-not $Name) { $Name = Read-Host 'Your name' }
    if ($Name -notmatch '^[A-Za-z0-9_\-\[\]]{1,30}$') { throw "Invalid name '$Name' (letters, digits, _ - [ ] only)." }
    [void](New-Item $configDir -ItemType Directory -Force)
    [IO.File]::WriteAllText($nameFile, $Name, $utf8)

    $script:EngineDir = Get-EngineDir $Engine
    if (-not (Test-Path (Join-Path $script:EngineDir 'spring.exe'))) { throw "No spring.exe in '$($script:EngineDir)'." }

    if ($Mode -eq 'host') { Start-Host } else { Start-Join }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    if (-not $env:ZK_DIRECT_NOPAUSE) { Read-Host 'Press Enter to close' | Out-Null }
}
