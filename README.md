# Homelab

Private infra repo: shared **bootstrap** templates, **per-host** env, and optional **system** overrides.

## Layout

```text
homelab/
├── bootstrap/
│   ├── setup.sh              # installer (run from repo root)
│   └── templates/            # canonical files → /opt/homelab
├── hosts/<name>/             # host.env, secrets.env (gitignored when real)
├── systems/<name>/           # optional overrides (mirror templates/ paths)
└── docs/
```

Deployed stack path: `/opt/homelab` (Docker Compose + configs).

## Quick start (pi5-sol)

```bash
cd ~/homelab
cp hosts/pi5-sol/host.env.example hosts/pi5-sol/host.env
cp hosts/pi5-sol/secrets.env.example hosts/pi5-sol/secrets.env
# edit both files, then:
sudo ./bootstrap/setup.sh --host pi5-sol --install
sudo ./bootstrap/setup.sh --test-nvme
```

If `hostname` matches a folder under `hosts/` (this Pi: `sol` → `hosts/sol` → `pi5-sol`), `--host` can be omitted.

## Day-two commands

| Command | Purpose |
|---------|---------|
| `sudo ./bootstrap/setup.sh --update` | Pull images and recreate containers |
| `sudo ./bootstrap/setup.sh --backup` | Archive configs |
| `hl`, `hlstatus`, `hltest` | Shell aliases after install |

## Adding another machine

1. `hosts/newbox/` — `host.env.example`, `secrets.env.example`, `README.md`
2. Optional `systems/newbox/` — files that override `bootstrap/templates/` (same relative paths)
3. `sudo ./bootstrap/setup.sh --host newbox --install`

## Migrating from `shell-scripts/homelab-setup`

That folder is legacy; this repo is the source of truth. Templates were seeded from `/opt/homelab` on pi5-sol.
