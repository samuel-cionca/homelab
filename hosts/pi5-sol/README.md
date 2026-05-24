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

## Pi 5 power monitoring (PMIC + throttling)

The Pi 5 USB-C input does not expose its negotiated current draw to userland, but the on-board PMIC and firmware expose enough to detect a weak supply: under-voltage flags, internal rail voltages (including `EXT5V_V` after the USB-C input), and per-rail currents.

The installer ships a small textfile exporter that scrapes those values via `vcgencmd` and writes Prometheus metrics for `node-exporter` to pick up. The service is only installed on hardware detected as **Raspberry Pi 5**.

Installed pieces:

- `/opt/homelab/scripts/pi5-power-exporter.sh` — host-side scraper.
- `/etc/systemd/system/pi5-power-exporter.{service,timer}` — runs the scraper every 15 s.
- `/opt/homelab/configs/node-exporter/textfile/pi5_power.prom` — output, read-only mounted into `node-exporter`.
- Grafana dashboard **Pi 5 power & throttling** (`pi5-power.json`).

Metrics exposed under `node-exporter` (`:9100`):

| Metric | Meaning |
|---|---|
| `pi5_throttled_flags` | Raw `vcgencmd get_throttled` bitmask |
| `pi5_throttled{flag="undervoltage_now"}` | 1 while the PSU is dipping right now |
| `pi5_throttled{flag="undervoltage_since_boot"}` | 1 if any dip happened since boot (sticky) |
| `pi5_throttled{flag="throttled_now"}` / `…since_boot` | CPU/GPU throttling state |
| `pi5_pmic_volts{rail="EXT5V_V"}` | Board input rail (~5.1 V healthy) |
| `pi5_pmic_volts{rail="VDD_CORE_V"}` / `3V3_SYS_V` / … | All PMIC voltage rails |
| `pi5_pmic_current_amps{rail="VDD_CORE_A"}` / … | All PMIC current rails (amps) |
| `pi5_measure_volts{rail="core"}` / `sdram_c` / … | Firmware-reported rails |
| `pi5_power_exporter_up` | 1 if `vcgencmd` is usable on this host |
| `pi5_power_exporter_last_run_seconds` | Unix timestamp of the last successful run |

Verify after install:

```bash
systemctl status pi5-power-exporter.timer
cat /opt/homelab/configs/node-exporter/textfile/pi5_power.prom
curl -s http://127.0.0.1:9100/metrics | grep '^pi5_'
/opt/homelab/scripts/test.sh pi5-power
```

Diagnosing freezes — the **single** signal that proves a PSU/cable issue is:

```bash
vcgencmd get_throttled
```

Any non-zero bit 0 (current) or bit 16 (since boot) means under-voltage. The `Pi 5 power & throttling` Grafana dashboard plots both alongside `EXT5V_V` so you can correlate a dip with the moment of the freeze.

There is no Linux interface that reports the input current at the USB-C port. If you need actual amps drawn from the wall, use an inline USB-C power meter. Everything else (rail voltages, internal currents, under-voltage flags) is captured by the exporter above.
