# setup-vps.sh

One-shot bootstrap for a fresh **Ubuntu or Debian** VPS. Run it as root, answer the
questions, walk away. Safe to re-run.

```sh
# on the fresh box, as root
curl -fsSL https://raw.githubusercontent.com/realChriss/linux-shell-setup/main/setup-vps.sh | bash
```

No flags, no options — the script asks everything up front, shows you the plan, and
waits for a final confirmation before it touches anything. The prompts still work when
piped, because it reads your answers from `/dev/tty`, not from stdin.

It must be `bash`, not `sh` — the script uses bash-only features.

## What it asks

1. Hostname (enter keeps the current one)
2. Remove snap, telemetry and Ubuntu Pro / MOTD ads — Ubuntu only, see below
3. Install zoxide
4. Install Docker + Compose
5. Install Bun
6. Proceed?

## What it does

| Step | Notes |
| --- | --- |
| System upgrade | `apt-get dist-upgrade`, non-interactive, keeps your existing config files |
| **De-bloat** (Ubuntu only) | optional; see below |
| Zsh + Oh My Zsh | for root, with `git`, `docker`, `docker-compose`, `zsh-autosuggestions`, `zsh-syntax-highlighting` |
| zoxide | optional; upstream installer into `~/.local/bin`, wired into `.zshrc` — `z <dir>` to jump, `zi` to pick |
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

## After it finishes

```sh
exec zsh          # or just log out and back in
reboot            # recommended after a full upgrade
```
