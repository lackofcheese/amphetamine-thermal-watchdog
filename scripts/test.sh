#!/bin/zsh
set -euo pipefail

binary="${1:-build/amphetamine-thermal-watchdog}"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$tmp_home"' EXIT

export HOME="$tmp_home"

normal_output="$($binary --once --dry-run --ignore-trip-latch)"
[[ "$normal_output" == *"Sample: thermal="* ]]

thermal_output="$($binary --once --dry-run --ignore-trip-latch --simulate-thermal serious)"
[[ "$thermal_output" == *"TRIP: system thermal state is serious"* ]]
[[ "$thermal_output" == *"Dry run: would end Amphetamine session and request system sleep"* ]]

battery_output="$($binary --once --dry-run --ignore-trip-latch --battery-cutoff-c -20)"
if [[ "$battery_output" == *"battery=unavailable"* ]]; then
  echo "Battery sensor unavailable; battery cutoff assertion skipped."
else
  [[ "$battery_output" == *"TRIP: battery temperature"* ]]
fi

rendered_plist="$tmp_home/guard.plist"
sed "s|@HOME@|$tmp_home|g" LaunchAgents/com.lackofcheese.amphetamine-thermal-watchdog.plist.in > "$rendered_plist"
plutil -lint "$rendered_plist" >/dev/null

grep -q 'legacy_label="com.lackofcheese.amphetamine-thermal-guard"' scripts/install.sh
grep -q 'launchctl bootout "$domain/$legacy_label"' scripts/install.sh

echo "All non-destructive tests passed."
