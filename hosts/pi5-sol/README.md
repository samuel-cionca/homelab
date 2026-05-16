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
