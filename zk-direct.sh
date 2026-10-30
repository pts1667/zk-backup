#!/usr/bin/env bash
# Runs zk-direct.ps1 with PowerShell 7 on Linux, in the terminal (there's no window on Linux):
#   ./zk-direct.sh join 203.0.113.5 -Name Bob
#   ./zk-direct.sh host -Name Tom [-Map "TitanDuel 2.2"]
# Without PowerShell, it offers to download it into ~/.local/share/zk-direct (no root needed).
set -e
dir=$(cd "$(dirname "$0")" && pwd)
local_pwsh="${XDG_DATA_HOME:-$HOME/.local/share}/zk-direct/powershell"

pwsh=$(command -v pwsh || true)
if [ -z "$pwsh" ] && [ -x "$local_pwsh/pwsh" ]; then pwsh="$local_pwsh/pwsh"; fi

if [ -z "$pwsh" ]; then
    case "$(uname -m)" in
        x86_64) arch=x64 ;;
        aarch64 | arm64) arch=arm64 ;;
        *) echo "PowerShell 7 isn't installed, and there's no download for $(uname -m). See https://aka.ms/powershell" >&2; exit 1 ;;
    esac
    echo "zk-direct needs PowerShell 7 (pwsh), which isn't installed."
    echo "Install it from your package manager (see https://aka.ms/install-powershell),"
    read -r -p "or download it (a 70 MB download, 170 MB installed) into $local_pwsh? [Y/n] " answer
    case "$answer" in [nN]*) exit 1 ;; esac
    if command -v curl > /dev/null; then fetch() { curl -fsSL "$1"; }; else fetch() { wget -qO- "$1"; }; fi
    version=$(fetch https://api.github.com/repos/PowerShell/PowerShell/releases/latest | grep -m1 '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [ -z "$version" ]; then echo "Couldn't find the latest PowerShell version on GitHub." >&2; exit 1; fi
    echo "Downloading PowerShell $version..."
    rm -rf "$local_pwsh.part"
    mkdir -p "$local_pwsh.part"
    fetch "https://github.com/PowerShell/PowerShell/releases/download/v$version/powershell-$version-linux-$arch.tar.gz" | tar -xz -C "$local_pwsh.part"
    chmod +x "$local_pwsh.part/pwsh"
    rm -rf "$local_pwsh"
    mv "$local_pwsh.part" "$local_pwsh"
    pwsh="$local_pwsh/pwsh"
fi

# pwsh refuses to start without ICU (libicu), which minimal systems may lack; the script doesn't need it
if command -v ldconfig > /dev/null && ! ldconfig -p 2> /dev/null | grep -q libicuuc; then
    export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
fi

exec "$pwsh" -NoLogo -NoProfile -File "$dir/zk-direct.ps1" "$@"
