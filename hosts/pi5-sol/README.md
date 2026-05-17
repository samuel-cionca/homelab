# pi5-sol

Raspberry Pi 5 homelab host (`hostname`: **sol** — `hosts/sol` symlinks here for auto-detect).

Docker stack under `/opt/homelab`.

1. Copy `host.env.example` → `host.env` and edit.
2. Copy `secrets.env.example` → `secrets.env` and set real passwords.
3. Install from repo root:

```bash
sudo ./bootstrap/setup.sh --host pi5-sol --install
```

Optional machine-specific template overrides live in `systems/pi5-sol/` (same paths as `bootstrap/templates/`).

## Pi 5 Wi‑Fi / Bluetooth (automatic)

### Why this is in the bootstrap

On **this** Pi 5 we saw flaky behavior whenever the Bluetooth keyboard went idle or was not actively connected: the board could **appear frozen** or unresponsive for stretches, and **Wi‑Fi** would sometimes **stop working**. Those symptoms line up badly with combo **2.4 GHz Wi‑Fi + Bluetooth coexistence**, aggressive **Wi‑Fi power savings**, and **Bluetooth link-layer options** some peripherals do not tolerate well.

The install step does not prove a root cause—it applies two **widely recommended mitigations**: turn off **NetworkManager Wi‑Fi powersave**, and disable Bluetooth **ERTM** via `modprobe`. If your Pi 5 behaves fine without them, you can drop the files or override templates under `systems/pi5-sol/` after you understand the trade-offs.

Install detects **Raspberry Pi 5** via `/proc/device-tree/model`. On Pi 5 it:

1. Writes `/etc/NetworkManager/conf.d/wifi-powersave.conf` (`wifi.powersave = 2`) and restarts **NetworkManager** when that service is installed and active.
2. Writes `/etc/modprobe.d/99-homelab-bluetooth-disable-ertm.conf` with `options bluetooth disable_ertm=Y` (**reboot** once so the bluetooth module picks it up if it was already loaded).

Override templates via `systems/pi5-sol/pi5/wifi-powersave.conf` and `systems/pi5-sol/pi5/bluetooth-disable-ertm.conf`.

Verify after reboot (**interface name** may vary; `wlan0` is typical):

```bash
iw dev wlan0 get power_save
cat /sys/module/bluetooth/parameters/disable_ertm
```

Expected interaction (commands and outputs in order):

```text
iw dev wlan0 get power_save
Power save: off
cat /sys/module/bluetooth/parameters/disable_ertm
Y
```
