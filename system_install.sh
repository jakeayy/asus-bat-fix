#!/usr/bin/env bash
# Install asus_bat_fix permanently with DKMS, or remove it.
#
# Usage: sudo ./system_install.sh [--ac-name NAME]
#        sudo ./system_install.sh --uninstall
#
# The install loads the module at every boot and DKMS rebuilds it for each new
# kernel. Running it again reinstalls (or upgrades) cleanly.

set -euo pipefail

name=asus-bat-fix
module=asus_bat_fix
src_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
load_conf=/etc/modules-load.d/$name.conf
opts_conf=/etc/modprobe.d/$name.conf
kver=$(uname -r)

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	sed -n '4,5s/^# //p' "${BASH_SOURCE[0]}"
	exit "$1"
}

action=install
ac_name=
while (( $# > 0 )); do
	case $1 in
	--uninstall) action=uninstall ;;
	--ac-name)
		(( $# > 1 )) || usage 2
		ac_name=$2
		shift
		;;
	-h | --help) usage 0 ;;
	*) usage 2 ;;
	esac
	shift
done

(( EUID == 0 )) || die "run as root: sudo $0"

version=$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$src_dir/dkms.conf")
[[ -n $version ]] || die "could not read PACKAGE_VERSION from $src_dir/dkms.conf"

# Unload the module and remove every installed version, so installs can't stack.
remove_installed() {
	if [[ -d /sys/module/$module ]]; then
		rmmod "$module"
	fi
	if command -v dkms >/dev/null; then
		local v
		for v in $(dkms status -m "$name" 2>/dev/null | sed -n "s|^$name/\([^,:]*\)[,:].*|\1|p" | sort -u); do
			echo "Removing $name/$v from DKMS"
			dkms remove "$name/$v" --all >/dev/null
		done
	fi
	rm -rf /usr/src/"$name"-*
}

if [[ $action == uninstall ]]; then
	remove_installed
	rm -f "$load_conf" "$opts_conf"
	echo "Uninstalled $name."
	exit 0
fi

# Check build dependencies before touching anything.
missing=()
command -v dkms >/dev/null || missing+=(dkms)
command -v make >/dev/null || missing+=(make)
command -v gcc >/dev/null || missing+=(gcc)
[[ -e /lib/modules/$kver/build ]] || missing+=("kernel headers for $kver")
if (( ${#missing[@]} > 0 )); then
	echo "Missing: ${missing[*]}" >&2
	if command -v dnf >/dev/null; then
		echo "Install with: sudo dnf install dkms make gcc kernel-devel-$kver" >&2
	elif command -v apt-get >/dev/null; then
		echo "Install with: sudo apt install dkms build-essential linux-headers-$kver" >&2
	elif command -v pacman >/dev/null; then
		echo "Install with: sudo pacman -S --needed dkms base-devel linux-headers" >&2
		echo "(use linux-lts-headers, linux-zen-headers, ... for other kernels)" >&2
	elif command -v zypper >/dev/null; then
		echo "Install with: sudo zypper install dkms make gcc kernel-default-devel" >&2
	fi
	exit 1
fi

# Find the AC adapter unless one was given.
if [[ -z $ac_name ]]; then
	for d in /sys/class/power_supply/*; do
		if [[ -r $d/type && $(<"$d/type") == Mains ]]; then
			ac_name=${d##*/}
			break
		fi
	done
	[[ -n $ac_name ]] || die "no AC adapter found in /sys/class/power_supply; pass --ac-name NAME"
fi
[[ -d /sys/class/power_supply/$ac_name ]] || die "power supply '$ac_name' does not exist"
echo "AC adapter: $ac_name"

remove_installed

echo "Installing $name/$version for kernel $kver"
install -d "/usr/src/$name-$version"
install -m 644 "$src_dir"/{Makefile,dkms.conf,asus_bat_fix.c} "/usr/src/$name-$version/"
dkms add "$name/$version" >/dev/null
dkms install "$name/$version" >/dev/null

echo "$module" >"$load_conf"
if [[ $ac_name != ADP0 ]]; then
	echo "options $module ac_name=$ac_name" >"$opts_conf"
else
	rm -f "$opts_conf"
fi

# Some distributions rebuild DKMS modules at boot through this service.
if command -v systemctl >/dev/null && systemctl list-unit-files dkms.service >/dev/null 2>&1 &&
	systemctl list-unit-files dkms.service | grep -q '^dkms\.service'; then
	systemctl enable dkms.service >/dev/null 2>&1 || true
fi

if ! modprobe "$module"; then
	if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -q enabled; then
		echo
		echo "Secure Boot is on, so the kernel needs the DKMS signing key enrolled once:"
		echo "  sudo mokutil --import /var/lib/dkms/mok.pub"
		echo "Then reboot and confirm the enrollment in the MOK Manager screen."
		echo "The module is installed and will load at boot after that."
		exit 1
	fi
	die "modprobe $module failed; see 'sudo dmesg | tail'"
fi

echo
dkms status -m "$name"
echo "Installed and loaded. Unplug the charger and run ./test.sh to check it."
