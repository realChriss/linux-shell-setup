# setup-vps.sh

One-shot bootstrap for a fresh **Ubuntu or Debian** VPS. Run it as root, answer three
questions, walk away. Safe to re-run.

```sh
# on the fresh box, as root
curl -fsSLO https://<your-host>/setup-vps.sh
chmod +x setup-vps.sh
./setup-vps.sh
```

## What it does

| Step | Notes |
| --- | --- |
| System upgrade | `apt-get dist-upgrade`, non-interactive, keeps your existing config files |
| **De-bloat** (Ubuntu only) | see below |
| Zsh + Oh My Zsh | for root, with `git`, `docker`, `docker-compose`, `zsh-autosuggestions`, `zsh-syntax-highlighting` |
| zoxide | upstream installer into `~/.local/bin`, wired into `.zshrc` — `z <dir>` to jump, `zi` to pick |
| Docker + Compose | optional; official Docker repo, `docker-ce` + `docker-compose-plugin` (`docker compose`) |
| Bun | optional; official installer into `~/.bun` (pulls in `unzip` first) |
| Hostname | optional; `/etc/hostname`, `/etc/hosts`, and tells cloud-init to stop resetting it |
| Login shell | `chsh` root to zsh |
| Cleanup | `autoremove --purge`, `autoclean`, `clean`, journal vacuum |

Everything is logged to `/var/log/vps-setup-<timestamp>.log`.

### De-bloat (Ubuntu only)

* **snap** — every installed snap removed, `snapd` purged, `apt-mark hold`ed, and pinned at
  priority `-10` in `/etc/apt/preferences.d/no-snap.pref` so nothing can pull it back in.
  `/snap`, `/var/snap`, `/var/lib/snapd` deleted.
  *Side effect:* installing `lxd` or anything else snap-backed will now fail. That's the point.
* **telemetry** — `popularity-contest`, `ubuntu-report`, `apport`, `whoopsie`, `landscape-common`.
* **MOTD ads** — `motd-news` disabled, and the ESM / livepatch / release-upgrade nag scripts in
  `/etc/update-motd.d/` are made non-executable.
* **Ubuntu Pro** — `ubuntu-advantage-tools` / `ubuntu-pro-client` purged plus the apt ESM hook.
  This also drops the `ubuntu-minimal` / `ubuntu-server` metapackages, which is harmless — but
  it means their dependencies suddenly look orphaned, so before that purge the script
  `apt-mark manual`s the core set (sshd, cloud-init, netplan, kernel, grub…), and **both** the
  purge and the final `autoremove` are dry-run first and skipped entirely if they would touch
  anything on the protected list. You cannot lock yourself out with this.

`cloud-init` and `unattended-upgrades` are deliberately **kept** — removing cloud-init breaks
network config and SSH key injection on Hetzner, DigitalOcean and Vultr.

Debian skips this whole section.

## Options

```
--hostname=NAME   set this hostname instead of asking
--keep-hostname   leave the hostname untouched
--docker | --no-docker
--bun    | --no-bun
--no-debloat      keep snap / telemetry / Pro & MOTD ads
-y, --yes         never prompt; defaults are: keep hostname, install Docker, install Bun
-h, --help
```

Any question you answer with a flag isn't asked. Fully unattended, e.g. from cloud-init:

```sh
./setup-vps.sh --yes --hostname=web-01 --docker --no-bun
```

## After it finishes

```sh
exec zsh          # or just log out and back in
reboot            # recommended after a full upgrade
```
