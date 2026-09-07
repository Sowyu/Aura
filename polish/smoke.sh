#!/bin/bash
# Keyboard-only smoke test of a Debug build. No coordinate clicks: they land on the
# wrong window under paneru. Screenshots go to /tmp/aura-shots/smoke-*.png.
set -u
APP=${1:-/tmp/dd-aura-main/Build/Products/Debug/Aura.app}
A='tell application "System Events" to tell process "Aura"'
key() { osascript -e "$A to keystroke \"$1\" using {$2}"; }
code() { osascript -e "$A to key code $1"; }
shot() { sleep ${2:-0.8}; screencapture -x "/tmp/aura-shots/smoke-$1.png"; sips -Z 1400 "/tmp/aura-shots/smoke-$1.png" --out "/tmp/aura-shots/smoke-$1-s.png" >/dev/null; }
pos() { osascript -e "$A to get position of window 1"; }
mkdir -p /tmp/aura-shots
pkill -x Aura; sleep 2; open -n "$APP"; sleep 6
osascript -e 'tell application "Aura" to activate'; sleep 0.5
echo "launch pos: $(pos)"
shot 00-launch 0.5
# 1. ⌘T, type, Enter
key t "command down"; shot 01-cmdT
osascript -e "$A to keystroke \"example.com\""; shot 02-typed
code 36; shot 03-loaded 4
echo "after first load pos: $(pos)"
# 2. ⌘T twice must keep the panel; Escape closes
key t "command down"; osascript -e 'delay 0.15'; key t "command down"; osascript -e "$A to keystroke \"double\""; shot 04-doubleT
code 53; shot 05-esc 0.5
# 3. ⌘L edits the address bar, Escape leaves it
key l "command down"; shot 06-cmdL
code 53; sleep 0.3
# 4. ⌘F find bar, Escape
key f "command down"; osascript -e "$A to keystroke \"example\""; shot 07-find
code 53; sleep 0.3
# 5. Control-Tab switcher
osascript -e "$A to key code 48 using {control down}"; shot 08-switcher
code 53; sleep 0.3
# 6. ⌘, settings page
key , "command down"; shot 09-settings 1.5
# 7. ⌘W closes settings tab, ⌘⇧T reopens
key w "command down"; shot 10-closed
key t "command down, shift down"; shot 11-reopened 1.5
# 8. Command palette
key t "command down"; osascript -e "$A to keystroke \">rel\""; shot 12-palette
code 53
echo "final pos: $(pos)"
echo "done"
