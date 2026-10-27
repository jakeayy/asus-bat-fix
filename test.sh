#!/usr/bin/env bash
# Check whether this laptop reports "Not charging" while running on battery,
# the firmware bug that asus_bat_fix works around. No root needed.
#
# Usage: ./test.sh [seconds]   (default: 30)
#
# Exit codes: 0 no bug seen, 1 bug seen, 2 error, 3 charger never unplugged.

set -uo pipefail

duration=${1:-30}
if ! [[ $duration =~ ^[0-9]+$ ]] || (( duration == 0 )); then
	echo "usage: $0 [seconds]" >&2
	exit 2
fi

ps=/sys/class/power_supply
ac=
bat=
for d in "$ps"/*; do
	[[ -r $d/type ]] || continue
	type=$(<"$d/type")
	if [[ $type == Mains && -z $ac && -r $d/online ]]; then
		ac=${d##*/}
	elif [[ $type == Battery && -z $bat && -r $d/status ]]; then
		bat=${d##*/}
	fi
done
if [[ -z $ac || -z $bat ]]; then
	echo "error: could not find an AC adapter and a battery in $ps" >&2
	exit 2
fi

loaded=false
[[ -d /sys/module/asus_bat_fix ]] && loaded=true

echo "Battery: $bat, charger: $ac, asus_bat_fix loaded: $loaded"
echo "Unplug the charger now. Sampling every 0.5 s for $duration s..."

total=0
on_battery=0
bad=0
end=$((SECONDS + duration))
while (( SECONDS < end )); do
	online=$(<"$ps/$ac/online")
	status=$(<"$ps/$bat/status")
	total=$((total + 1))
	if [[ $online == 0 ]]; then
		on_battery=$((on_battery + 1))
		[[ $status == "Not charging" ]] && bad=$((bad + 1))
	fi
	if [[ -t 1 ]]; then
		printf '\r  %3d s left   charger online: %s   battery: %-13s' \
			$((end - SECONDS)) "$online" "$status"
	fi
	sleep 0.5
done
[[ -t 1 ]] && printf '\n'
printf '\n'

if (( on_battery == 0 )); then
	echo "The charger was plugged in the whole time. Unplug it and run the test again."
	exit 3
fi

echo "$on_battery of $total readings were taken on battery; $bad of them said \"Not charging\"."
if (( bad > 0 )); then
	if $loaded; then
		echo "Bug present even though asus_bat_fix is loaded. Please open an issue."
	else
		echo "Affected: this laptop has the bug, and asus_bat_fix should fix it."
	fi
	exit 1
fi

if $loaded; then
	echo "No \"Not charging\" readings on battery: asus_bat_fix is working."
else
	echo "No sign of the bug during this test, so this laptop probably doesn't need asus_bat_fix."
fi
exit 0
