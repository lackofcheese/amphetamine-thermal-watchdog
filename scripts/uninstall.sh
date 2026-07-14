#!/bin/zsh
set -euo pipefail

label="com.lackofcheese.amphetamine-thermal-watchdog"
domain="gui/$(id -u)"
launch_agent="$HOME/Library/LaunchAgents/$label.plist"
latch_dir="$HOME/Library/Application Support/AmphetamineThermalGuard"
log="$HOME/Library/Logs/AmphetamineThermalWatchdog.log"

launchctl bootout "$domain/$label" 2>/dev/null || true
rm -f "$launch_agent"
rm -f "$HOME/.local/bin/amphetamine-thermal-watchdog"
rm -f "$HOME/.local/bin/amphetamine-thermal-watchdogctl"
rm -rf "$HOME/.local/share/amphetamine-thermal-watchdog"
rm -rf "$latch_dir"

if [[ "${1:-}" == "--purge-log" ]]; then
  rm -f "$log"
fi

echo "Uninstalled Amphetamine Thermal Watchdog."
