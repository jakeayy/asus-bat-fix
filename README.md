# asus-bat-fix

A small Linux kernel module that fixes the battery status flickering between
**charging** and **discharging** on the ASUS Vivobook 16 M1607KA when the
charger is **unplugged**.

## The problem

When the laptop is running on battery, its firmware sometimes reports the battery
as neither charging nor discharging. The kernel turns that into
`Not charging`, so `/sys/class/power_supply/BAT0/status` switches about once a
second:

```
AC=0  BAT=Discharging
AC=0  BAT=Not charging
AC=0  BAT=Discharging
AC=0  BAT=Not charging
```

upower reports `Not charging` as `pending-charge`. GNOME and other desktops
then show a charging icon, so the battery looks as if the charger were being
plugged in and out. Nothing is actually connecting, the charger stays offline,
and the battery keeps draining normally. It's purely a display bug, and it goes
away while the charger is plugged in.

## Are you affected?

Unplug the charger and run:

```sh
while true; do
  echo "AC=$(cat /sys/class/power_supply/ADP0/online) BAT=$(cat /sys/class/power_supply/BAT0/status)"
  sleep 0.5
done
```

If you see `AC=0` together with `BAT=Not charging`, this module will help. If
your charger isn't called `ADP0`, look in `/sys/class/power_supply/` for the
entry whose `type` is `Mains`. See [Other models](#other-models).

## How it works

The module hooks the kernel's ACPI battery driver (`acpi_battery_get_property`)
using a kretprobe. When the driver returns `Not charging` while the charger is
offline, the module changes the value to `Discharging`. Everything that reads the
battery status sees the corrected value: sysfs, uevents, upower and the desktop.

- While the charger is plugged in, the module changes nothing. A real
  `Not charging` (for example, when a charge limit is reached) is still reported.
- The probe never asks the firmware for the charger state, because that can
  sleep, which isn't allowed inside a probe. Instead, it keeps a cached copy of
  the charger state and updates it whenever the charger reports a change.

## Requirements

- Kernel headers for your running kernel. On Fedora:
  `sudo dnf install kernel-devel`. On Debian and Ubuntu:
  `sudo apt install linux-headers-$(uname -r)`.
- `make` and `gcc`
- `dkms`, for the permanent install
- A kernel with `CONFIG_KPROBES` and `CONFIG_KRETPROBES`. Most distribution
  kernels have both.

### Secure Boot

With Secure Boot enabled, the kernel only loads signed modules. DKMS 3.x signs
the modules it builds with its own key, but you need to enroll that key once:

```sh
sudo mokutil --import /var/lib/dkms/mok.pub
```

Then reboot and confirm the enrollment in the blue MOK Manager screen. The manual
`insmod` test below won't work with Secure Boot on, so skip straight to the DKMS
install.

## Try it first (optional)

Build the module and load it until the next reboot:

```sh
git clone https://github.com/jakeayy/asus-bat-fix.git
cd asus-bat-fix
make
sudo insmod asus_bat_fix.ko
sudo dmesg | grep asus_bat_fix
```

You should see `asus_bat_fix: loaded, AC adapter ADP0 is online` (or
`offline`). Unplug the charger and run the loop from
[Are you affected?](#are-you-affected) again. The status should stay on
`Discharging`.

To unload it: `sudo rmmod asus_bat_fix`

## Install permanently with DKMS

DKMS rebuilds the module automatically every time you install a new kernel.

```sh
git clone https://github.com/jakeayy/asus-bat-fix.git
sudo cp -r asus-bat-fix /usr/src/asus-bat-fix-1.0
sudo dkms install asus-bat-fix/1.0

# Load it at every boot, and load it now
echo asus_bat_fix | sudo tee /etc/modules-load.d/asus-bat-fix.conf
sudo modprobe asus_bat_fix
```

On Fedora, also make sure the DKMS boot service is enabled:
`sudo systemctl enable dkms`. It rebuilds the module at boot if that didn't
happen during the kernel update.

To check it:

```sh
dkms status                 # asus-bat-fix/1.0, <kernel>, x86_64: installed
lsmod | grep asus_bat_fix
```

## Uninstall

```sh
sudo rmmod asus_bat_fix
sudo dkms remove asus-bat-fix/1.0 --all
sudo rm -r /usr/src/asus-bat-fix-1.0 /etc/modules-load.d/asus-bat-fix.conf
```

## Other models

The module isn't tied to the M1607KA. It only acts when the battery reports
`Not charging` while the charger is offline. It should therefore be harmless on
other laptops, and may help other ASUS models with the same firmware bug.

If your charger has a different name, pass it as a parameter:

```sh
sudo insmod asus_bat_fix.ko ac_name=AC0
```

For a DKMS install, set it in `/etc/modprobe.d/asus-bat-fix.conf`:

```
options asus_bat_fix ac_name=AC0
```

## Notes

- Loading the module adds the kernel log lines `loading out-of-tree module
  taints kernel` and, without Secure Boot, `module verification failed`. Both
  are normal for a module that isn't part of the kernel and is unsigned.
- When reporting kernel bugs, unload the module first so the kernel isn't
  marked as modified.
- This is a workaround. The proper fix is a BIOS update from ASUS or an
  upstream kernel quirk for this model. Once either exists, uninstall this
  module.

Tested on: ASUS Vivobook 16 M1607KA, BIOS M1607KA.331, Fedora 45, kernel
7.2.11.

## License

GPL-2.0. See [LICENSE](LICENSE).
