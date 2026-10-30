# zk-backup

Play Zero-K multiplayer by direct IP while the official servers are down. Windows only; needs Zero-K installed (Steam or standalone).

If your install is missing engine `2026.07.04` or Zero-K `v1.14.10.3`, download `engine-2026.07.04-win64.zip` and `zero-k-v1.14.10.3.sdz` from the Releases page into `bundle\`. The script copies them into your install.

## Join a game

```
zk-direct.cmd join <host-ip> -Name YourName
```

Chat in the lobby and wait for the host to start. Type `/spec` to spectate and `/play` to rejoin a team. If you're missing the map, the host sends it to you; a missing game version downloads automatically. When the match ends, you're back in the lobby.

## Host a game

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

- `-ZkPath "D:\Games\Zero-K"`: your Zero-K folder. Without it, Steam installs are found automatically, and otherwise you're asked once.
- `-Port 8452`, `-Map "TitanDuel 2.2"`: host settings.
- `zk-direct.cmd install`: makes `zkjoin://<ip>` links open the join flow.

## Updating the bundle

```
bundle\make-bundle.ps1 -ZkPath <a Zero-K install with the new version> [-Engine 2026.07.04] [-Game zk:stable]
```
