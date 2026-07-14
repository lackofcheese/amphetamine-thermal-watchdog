#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
binary="${1:-$repo_root/build/amphetamine-thermal-watchdog}"
label="com.lackofcheese.amphetamine-thermal-watchdog"
domain="gui/$(id -u)"
launch_agent="$HOME/Library/LaunchAgents/$label.plist"

if [[ ! -x "$binary" ]]; then
  echo "Missing executable: $binary" >&2
  echo "Run 'make' first." >&2
  exit 1
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/amphetamine-thermal-watchdog" "$HOME/Library/LaunchAgents"
install -m 755 "$binary" "$HOME/.local/bin/amphetamine-thermal-watchdog"
install -m 755 "$repo_root/scripts/amphetamine-thermal-watchdogctl" "$HOME/.local/bin/amphetamine-thermal-watchdogctl"
install -m 644 "$repo_root/Sources/AmphetamineThermalGuard/main.m" "$HOME/.local/share/amphetamine-thermal-watchdog/main.m"
sed "s|@HOME@|$HOME|g" "$repo_root/LaunchAgents/$label.plist.in" > "$launch_agent"
plutil -lint "$launch_agent"

launchctl bootout "$domain/$label" 2>/dev/null || true
launchctl bootstrap "$domain" "$launch_agent"

echo "Installed and started Amphetamine Thermal Watchdog."
echo "Status: $HOME/.local/bin/amphetamine-thermal-watchdogctl status"
