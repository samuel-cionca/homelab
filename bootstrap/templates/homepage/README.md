Homepage YAML/JS/CSS live in `bootstrap/templates/configs/homepage/` and are always synced to `/opt/homelab/configs/homepage/` on `--install` / `--sync`.

Do not put API keys in these files — use `HOMEPAGE_VAR_*` entries in `hosts/<name>/secrets.env`.
