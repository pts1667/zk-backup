# zk-backup

Play Zero-K multiplayer by direct IP while the official servers are down. Windows only; needs Zero-K installed (Steam or standalone).

Download the zip from the Releases page and extract it anywhere. It includes engine `2026.07.04` and Zero-K `v1.14.10.3`, which are copied into your install if it doesn't have them.

## Join a game

Double-click **`zk-direct.cmd`**, enter the host's address and press **Join**.

The first time, it asks for your Zero-K folder and name. Both are filled in from your install and Zero-K login.

Chat in the lobby and wait for the host to start. Use **Play as** to spectate or switch teams. If you're missing the map, the host sends it to you; a missing game version downloads automatically. When the match ends, you're back in the lobby.

In a terminal: `zk-direct.cmd join <host-ip> -Name YourName` (type `/spec` and `/play`).

## Host a game

Hosting runs in a terminal. Click **Host a game...** in the window, or run:

```
zk-direct.cmd host -Name YourName
```

1. Make port **8452** (TCP and UDP) reachable: forward it on your router, or have everyone join the same VPN (e.g. Tailscale).
2. Share the address the lobby prints.
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

Anything that isn't a command is chat. Players can use `/spec`, `/play` and `/team <n>` on themselves. Players missing the map get it from you automatically, and `/start` waits until they have it.

## Options

- `-ZkPath "D:\Games\Zero-K"`: your Zero-K folder for terminal use. Without it, the folder from setup is used, or one is found automatically. Change it in the window under **Settings...**.
- `-Port 8452`, `-Map "TitanDuel 2.2"`: host settings.
- `zk-direct.cmd install`: makes `zkjoin://<ip>` links open the window and join.

## Updating the bundle

```
bundle\make-bundle.ps1 -ZkPath <a Zero-K install with the new version> [-Engine 2026.07.04] [-Game zk:stable]
.\make-release.ps1    # writes dist\zk-direct-<game>.zip for the Releases page
```
