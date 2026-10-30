# zk-backup

Play Zero-K multiplayer by direct IP while the official servers are down. Needs Zero-K installed (Steam or standalone). On Windows there's a window; on [Linux](#linux) it runs in the terminal.

Download `zk-direct-...-windows.zip` (or `-linux.tar.gz`) from the Releases page and extract it anywhere. It includes Zero-K `v1.14.10.3`, and on Windows engine `2026.07.04`, which are copied into your install if it doesn't have them.

## Join a game

Double-click **`zk-direct.cmd`**, enter the host's address (an IP like `203.0.113.5`, or a `https://....trycloudflare.com` address) and press **Join**.

The first time, it asks for your Zero-K folder and name. Both are filled in from your install and Zero-K login.

Chat in the lobby and wait for the host to start. Use **Play as** to spectate or switch teams. If you're missing the map, the host sends it to you (through a Cloudflare tunnel it downloads from springfiles instead; if it isn't there, you sit that game out). A missing game version downloads automatically. When the match ends, you're back in the lobby.

In a terminal: `zk-direct.cmd join <host-ip> -Name YourName` (type `/spec` and `/play`).

## Host a game

Click **Host a game...** in the window, choose how players reach you (below) and press **Host**. The window becomes your lobby (its title says "(Hosting)"): type commands in the chat box and use **Play as** for yourself. **Stop hosting**, closing the window or `/quit` closes the lobby, after asking if other players are in it.

Or host in a terminal (Ctrl+C or `/quit` closes the lobby):

```
zk-direct.cmd host -Name YourName
```

1. Let players reach you, in either or both of these ways (the host window has a checkbox for each):
   - **Directly:** port **8452** (TCP and UDP). The script asks your router to open it (UPnP) and closes it when the lobby ends; it tells you if that didn't work. Otherwise forward it on your router, or have everyone join the same VPN (e.g. Tailscale).
   - **Through a Cloudflare tunnel:** works with no open port, e.g. behind a phone hotspot or a second router. Download `cloudflared-windows-amd64.exe` from [cloudflared's releases](https://github.com/cloudflare/cloudflared/releases) (no account needed) and pick it in the host window, or for the terminal put it next to `zk-direct.cmd` or leave it in Downloads. The lobby then starts a quick tunnel and prints a `https://....trycloudflare.com` address, which changes every time you host. It adds a little latency. Maps aren't sent through it: tunnel players download missing maps from springfiles, and a player who can't get the map stays in the lobby when you `/start`.
2. Share the address the lobby prints, or click the `zkjoinbk://` link above the player list to copy it.
3. Set up the match and type `/start`.

| Command | |
|---|---|
| `/team <name> <n\|spec>` | move a player or bot |
| `/spec <name>`, `/play <name>` | make a player spectate, put them back on a team |
| `/bot <team> [Easy\|Normal\|Hard\|Brutal]` | add an AI |
| `/map <name>` | change map |
| `/ffa` | everyone on their own team |
| `/kick <name>` | remove a player |
| `/start`, `/quit` | start the match, close the lobby |

Anything that isn't a command is chat. Players can use `/spec`, `/play` and `/team <n>` on themselves. Players missing the map get it automatically, and `/start` waits until they have it.

## Linux

zk-direct uses the Zero-K folder that `Zero-K.exe` (run with Mono) sets up, with its Linux engine. It runs in the terminal with PowerShell 7:

```
tar xzf zk-direct-*-linux.tar.gz && cd zk-direct
./zk-direct.sh join <address> -Name YourName
./zk-direct.sh host -Name YourName
```

- Without PowerShell 7 (`pwsh`), the script offers to download it into `~/.local/share/zk-direct` (no root needed). Or install it from your package manager.
- The Zero-K folder is looked for in Steam's libraries, your home folder, `~/Downloads` and `~/Games`, or asked for. `-ZkPath` or `ZK_DIR` sets it. Settings are kept in `~/.config/zk-direct`.
- Linux and Windows players can play together, as long as everyone has the host's engine version: start Zero-K once to update it.
- Hosting: UPnP needs `upnpc` (the `miniupnpc` package). For a Cloudflare tunnel, put `cloudflared` on your PATH, or download `cloudflared-linux-amd64` next to `zk-direct.sh` or into `~/Downloads`.
- The game's console output goes to `~/.config/zk-direct/spring.log` rather than over the lobby.
- There's no window and no `zkjoinbk://` links, but `./zk-direct.sh join zkjoinbk://...` takes a link's address.

## Options

- `-ZkPath "D:\Games\Zero-K"`: your Zero-K folder for terminal use. Without it, the folder from setup is used, or one is found automatically. Change it in the window under **Settings...**.
- `-Port 8452`, `-Map "TitanDuel 2.2"`: host settings. `-NoUpnp`: don't ask the router to open the port. `-NoTunnel`: don't start a Cloudflare tunnel even though cloudflared is there. `-Cloudflared <path>`: use that cloudflared.exe.
- `zk-direct.cmd install`: makes `zkjoinbk://<ip>` links open the window and join.

## Updating the bundle

```
bundle\make-bundle.ps1 -ZkPath <a Zero-K install with the new version> [-Engine 2026.07.04] [-Game zk:stable]
.\make-release.ps1    # writes dist\zk-direct-<game>-windows.zip and -linux.tar.gz (no engine) for the Releases page
```
