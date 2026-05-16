# Homelab

Reproducible Docker homelab bootstrap: shared **templates**, **per-host** env, and optional **system** overrides.

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

## Secret scan

Before pushing, run a local scan (requires Docker):

```bash
./scripts/gitleaks.sh
```

CI runs [gitleaks](https://github.com/gitleaks/gitleaks) on every push and pull request. Never commit real `host.env`, `secrets.env`, or `.env` files — only `*.example` placeholders.

**Optional (local only):** a `pre-push` hook under `~/.config/git/hooks/homelab/` runs the same scan before `git push`. After a fresh clone, enable it once:

```bash
git config --local core.hooksPath ~/.config/git/hooks/homelab
```

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
