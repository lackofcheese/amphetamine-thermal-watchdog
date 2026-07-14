# Amphetamine Thermal Watchdog

A small native macOS menu-bar watchdog that adds a thermal safety cutoff to
[Amphetamine](https://apps.apple.com/app/amphetamine/id937984704).

It monitors both macOS thermal pressure and the MacBook battery temperature.
If either reaches the configured cutoff, the watchdog:

1. records a persistent trip latch;
2. ends the current Amphetamine session through AppleScript;
3. asks macOS to sleep immediately; and
4. remains stopped until manually reset.

The menu-bar thermometer shows the live system thermal state and battery
temperature. It turns orange when the system reports elevated thermal pressure
or the battery reaches 35 °C.

## Defaults

- Battery cutoff: **40 °C**
- Poll interval: **15 seconds**
- Thermal cutoff: macOS `serious` or `critical`
- Installation scope: current user only

These defaults are a secondary safety mechanism, not permission to operate a
MacBook inside a bag or another poorly ventilated enclosure. Software can
fail, permissions can change, and hardware damage remains possible.

## Requirements

- macOS 11 or newer
- Apple Command Line Tools (`xcode-select --install`)
- Amphetamine installed in `/Applications`

The battery-temperature sensor is available on MacBooks. Desktop Macs still
use the system thermal-pressure cutoff, while the battery reading appears as
unavailable.

## Build and test

```sh
make
make test
```

The tests are non-destructive: simulated trips run in dry-run mode and never
end Amphetamine or sleep the Mac.

## Install

```sh
make install
```

The installer builds the native executable, installs a per-user LaunchAgent,
and starts it immediately. It also replaces the earlier
`com.lackofcheese.amphetamine-thermal-guard` manual installation, if present,
so only one watchdog and one menu-bar icon remain active. The legacy log and
trip latch are preserved. Installed paths are:

- `~/.local/bin/amphetamine-thermal-watchdog`
- `~/.local/bin/amphetamine-thermal-watchdogctl`
- `~/Library/LaunchAgents/com.lackofcheese.amphetamine-thermal-watchdog.plist`
- `~/Library/Logs/AmphetamineThermalWatchdog.log`

The first real cutoff may cause macOS to request permission for the watchdog
to control Amphetamine. Test that permission while the lid is open:

```sh
amphetamine-thermal-watchdogctl test
amphetamine-thermal-watchdogctl reset
```

The test ends an active Amphetamine session but deliberately does not sleep the
Mac.

## Control commands

```sh
amphetamine-thermal-watchdogctl status
amphetamine-thermal-watchdogctl logs
amphetamine-thermal-watchdogctl logs 100
amphetamine-thermal-watchdogctl test
amphetamine-thermal-watchdogctl reset
```

After a real trip, allow the Mac to cool before running `reset`.

## Uninstall

```sh
make uninstall
```

The uninstaller removes the LaunchAgent and installed executables. It preserves
the log unless invoked directly with `scripts/uninstall.sh --purge-log`.

## How it works

- `ProcessInfo.thermalState` supplies Apple's public system thermal-pressure
  signal.
- `AppleSmartBattery` supplies the battery temperature in tenths of a kelvin.
- AppKit supplies the native SF Symbol menu-bar icon.
- A successful cutoff exit is not restarted by launchd because the LaunchAgent
  uses `KeepAlive.SuccessfulExit = false`.

The cutoff is intentionally one-way: it never restarts Amphetamine or clears a
trip automatically.

## License

MIT
