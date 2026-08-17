#!/usr/bin/env bash
#
# setup-vps.sh — fresh Ubuntu/Debian VPS bootstrap. Run as root. Safe to re-run.
# See README.md, or ./setup-vps.sh --help
#

set -Eeuo pipefail

readonly ZSHRC="/root/.zshrc"
readonly OMZ_DIR="/root/.oh-my-zsh"
readonly OMZ_CUSTOM="${OMZ_DIR}/custom"
readonly BLOCK_START="# >>> vps-setup >>>"
readonly BLOCK_END="# <<< vps-setup <<<"
readonly OMZ_PLUGINS="git docker docker-compose zsh-autosuggestions zsh-syntax-highlighting"

# Purging Ubuntu Pro takes the ubuntu-minimal / ubuntu-server metapackages with it,
# which makes everything they pulled in look auto-removable. These must never be
# removed by that purge or by the autoremove at the end — losing openssh-server or
# cloud-init on a VPS means losing the VPS.
readonly PROTECTED_PKGS="\
openssh-server openssh-client openssh-sftp-server sudo systemd systemd-sysv systemd-resolved \
dbus cloud-init netplan.io ifupdown rsyslog cron apt dpkg bash coreutils util-linux mount \
login passwd e2fsprogs initramfs-tools grub-common grub-pc grub-efi-amd64 grub2-common \
iproute2 iputils-ping ca-certificates curl git zsh unzip tar"

ASSUME_YES=false
DO_DEBLOAT=true
NEW_HOSTNAME=""
WANT_HOSTNAME=""
WANT_DOCKER=""
WANT_BUN=""
WANT_ZOXIDE=""

WARNINGS=()
LOG=""

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

step() { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BLUE" "$*" "$C_RESET"; }
log()  { printf '    %s\n' "$*"; }
skip() { printf '    %s- %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ok()   { printf '    %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; WARNINGS+=("$*"); }
die()  { printf '\n%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local rc=$1 line=$2
    printf '\n%sxx aborted%s (exit %s, line %s)\n' "$C_RED" "$C_RESET" "$rc" "$line" >&2
    [[ -n "$LOG" ]] && printf 'Full log: %s\n' "$LOG" >&2
    exit "$rc"
}
trap 'on_error $? $LINENO' ERR

usage() {
    cat <<'EOF'
setup-vps.sh — bootstrap a fresh Ubuntu/Debian VPS (run as root)

Options:
  --hostname=NAME   set this hostname instead of asking
  --keep-hostname   leave the hostname untouched
  --docker          install Docker + Compose plugin (skip the question)
  --no-docker       do not install Docker
  --bun             install Bun (skip the question)
  --no-bun          do not install Bun
  --zoxide          install zoxide (skip the question)
  --no-zoxide       do not install zoxide
  --no-debloat      keep snap / Ubuntu telemetry / Pro & MOTD ads
  -y, --yes         never prompt; use defaults for anything not passed as a flag
                    (defaults: keep hostname, install Docker, Bun and zoxide)
  -h, --help        show this help

Always done: system upgrade, zsh + Oh My Zsh (+ autosuggestions, syntax
highlighting, git/docker/docker-compose plugins), zsh as root's login shell,
apt cleanup. On Ubuntu, snap and the telemetry/ad packages are removed unless
--no-debloat is given.
EOF
}

# Reads from /dev/tty so `curl … | bash` still gets answers from the keyboard.
ask() {
    local prompt="$1" default="$2" reply=""
    if [[ "$ASSUME_YES" == true ]]; then
        printf '%s\n' "$default"; return 0
    fi
    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt" reply < /dev/tty || reply=""
    elif [[ -t 0 ]]; then
        read -r -p "$prompt" reply || reply=""
    else
        printf '%s\n' "$default"; return 0
    fi
    printf '%s\n' "${reply:-$default}"
}

confirm() {
    local prompt="$1" default="${2:-y}" hint="[Y/n]" answer
    [[ "${default,,}" == "n" ]] && hint="[y/N]"
    while true; do
        answer="$(ask "$prompt $hint " "$default")"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     printf '    please answer y or n\n' >&2 ;;
        esac
    done
}

valid_hostname() {
    local h="$1" label
    [[ ${#h} -le 253 ]] || return 1
    [[ "$h" != *".."* ]] || return 1
    [[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || return 1
    while IFS= read -r label; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
    done < <(tr '.' '\n' <<< "$h")
    return 0
}

have_systemd() { [[ -d /run/systemd/system ]]; }

sysd() {
    if have_systemd; then
        systemctl "$@" >/dev/null 2>&1 || true
    fi
    return 0
}

apt_get() {
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1 \
        apt-get -y -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef "$@"
}

pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

would_remove() {
    DEBIAN_FRONTEND=noninteractive apt-get -s "$@" 2>/dev/null | awk '/^Remv /{print $2}' || true
}

protected_hits() {
    local p hits=""
    for p in $1; do
        case " $PROTECTED_PKGS " in
            *" $p "*) hits+=" $p"; continue ;;
        esac
        case "$p" in
            linux-image-*|linux-headers-*|linux-generic*|linux-virtual*) hits+=" $p" ;;
        esac
    done
    printf '%s' "$hits"
}

purge_if_installed() {
    local pkgs=() p
    for p in "$@"; do
        if pkg_installed "$p"; then pkgs+=("$p"); fi
    done
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        return 0
    fi
    if apt_get purge "${pkgs[@]}"; then
        ok "purged: ${pkgs[*]}"
    else
        warn "could not purge: ${pkgs[*]}"
    fi
}

as_root_home() {
    env HOME=/root USER=root LOGNAME=root SHELL=/bin/bash "$@"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname=*)    WANT_HOSTNAME="${1#*=}" ;;
            --hostname)      shift; [[ $# -gt 0 ]] || die "--hostname needs a value"; WANT_HOSTNAME="$1" ;;
            --keep-hostname) WANT_HOSTNAME="keep" ;;
            --docker)        WANT_DOCKER=true ;;
            --no-docker)     WANT_DOCKER=false ;;
            --bun)           WANT_BUN=true ;;
            --no-bun)        WANT_BUN=false ;;
            --zoxide)        WANT_ZOXIDE=true ;;
            --no-zoxide)     WANT_ZOXIDE=false ;;
            --no-debloat)    DO_DEBLOAT=false ;;
            -y|--yes)        ASSUME_YES=true ;;
            -h|--help)       usage; exit 0 ;;
            *)               usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    if [[ -n "$WANT_HOSTNAME" && "$WANT_HOSTNAME" != "keep" ]]; then
        valid_hostname "$WANT_HOSTNAME" || die "invalid hostname: $WANT_HOSTNAME"
    fi
}

detect_distro() {
    [[ $EUID -eq 0 ]] || die "run this as root (sudo -i, then ./setup-vps.sh)"
    [[ -r /etc/os-release ]] || die "/etc/os-release not found — unsupported system"

    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

    case "$DISTRO_ID" in
        ubuntu) DOCKER_DISTRO="ubuntu"; IS_UBUNTU=true ;;
        debian) DOCKER_DISTRO="debian"; IS_UBUNTU=false ;;
        *)
            if [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
                DOCKER_DISTRO="ubuntu"; IS_UBUNTU=true
            elif [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
                DOCKER_DISTRO="debian"; IS_UBUNTU=false
            else
                die "unsupported distro '$DISTRO_ID' — this script targets Ubuntu and Debian"
            fi
            ;;
    esac

    # Ubuntu derivatives carry UBUNTU_CODENAME; that is the one Docker's repo knows about.
    DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$DOCKER_CODENAME" ]] || warn "no release codename found; Docker repo setup may fail"
}

gather_answers() {
    local current answer
    current="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo localhost)"

    printf 'Detected: %s\n' "$DISTRO_NAME"

    if [[ "$WANT_HOSTNAME" == "keep" ]]; then
        NEW_HOSTNAME=""
    elif [[ -n "$WANT_HOSTNAME" ]]; then
        NEW_HOSTNAME="$WANT_HOSTNAME"
    elif [[ "$ASSUME_YES" == true ]]; then
        NEW_HOSTNAME=""
    else
        while true; do
            answer="$(ask "Hostname [$current] (enter to keep): " "$current")"
            if [[ "$answer" == "$current" ]]; then
                NEW_HOSTNAME=""; break
            elif valid_hostname "$answer"; then
                NEW_HOSTNAME="$answer"; break
            else
                printf '    invalid hostname — letters, digits, hyphens and dots only\n' >&2
            fi
        done
    fi

    if [[ -n "$WANT_DOCKER" ]]; then
        INSTALL_DOCKER="$WANT_DOCKER"
    elif [[ "$ASSUME_YES" == true ]]; then
        INSTALL_DOCKER=true
    elif confirm "Install Docker + Compose plugin?" y; then
        INSTALL_DOCKER=true
    else
        INSTALL_DOCKER=false
    fi

    if [[ -n "$WANT_BUN" ]]; then
        INSTALL_BUN="$WANT_BUN"
    elif [[ "$ASSUME_YES" == true ]]; then
        INSTALL_BUN=true
    elif confirm "Install Bun?" y; then
        INSTALL_BUN=true
    else
        INSTALL_BUN=false
    fi

    if [[ -n "$WANT_ZOXIDE" ]]; then
        INSTALL_ZOXIDE="$WANT_ZOXIDE"
    elif [[ "$ASSUME_YES" == true ]]; then
        INSTALL_ZOXIDE=true
    elif confirm "Install zoxide? ('z <dir>' to jump around)" y; then
        INSTALL_ZOXIDE=true
    else
        INSTALL_ZOXIDE=false
    fi

    local yn_docker yn_bun yn_zoxide yn_debloat
    yn_docker=$([[ "$INSTALL_DOCKER" == true ]] && echo yes || echo no)
    yn_bun=$([[ "$INSTALL_BUN" == true ]] && echo yes || echo no)
    yn_zoxide=$([[ "$INSTALL_ZOXIDE" == true ]] && echo yes || echo no)
    yn_debloat=$([[ "$DO_DEBLOAT" == true ]] && echo yes || echo no)
    [[ "$IS_UBUNTU" == true ]] || yn_debloat="n/a (Debian)"

    printf '\n%sPlan%s\n' "$C_BLUE" "$C_RESET"
    printf '  system upgrade ............ yes\n'
    printf '  remove snap + bloat ....... %s\n' "$yn_debloat"
    printf '  zsh + Oh My Zsh ........... yes (root)\n'
    printf '  zoxide .................... %s\n' "$yn_zoxide"
    printf '  docker + compose .......... %s\n' "$yn_docker"
    printf '  bun ....................... %s\n' "$yn_bun"
    printf '  hostname .................. %s\n\n' "${NEW_HOSTNAME:-unchanged ($current)}"

    if [[ "$ASSUME_YES" != true ]]; then
        confirm "Proceed?" y || { printf 'Nothing was changed.\n'; exit 0; }
    fi
}

set_hostname() {
    if [[ -z "$NEW_HOSTNAME" ]]; then
        step "Hostname"; skip "left unchanged"; return 0
    fi
    step "Setting hostname to $NEW_HOSTNAME"

    if have_systemd && command -v hostnamectl >/dev/null 2>&1; then
        hostnamectl set-hostname "$NEW_HOSTNAME" || warn "hostnamectl failed; writing /etc/hostname anyway"
    fi
    printf '%s\n' "$NEW_HOSTNAME" > /etc/hostname
    hostname "$NEW_HOSTNAME" 2>/dev/null || true

    local short="${NEW_HOSTNAME%%.*}" names="$NEW_HOSTNAME"
    [[ "$short" != "$NEW_HOSTNAME" ]] && names="$NEW_HOSTNAME $short"

    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i -E "s|^127\.0\.1\.1[[:space:]].*|127.0.1.1\t${names}|" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$names" >> /etc/hosts
    fi
    ok "/etc/hostname and /etc/hosts updated"

    # cloud-init re-applies the provider's hostname on every boot unless told not to.
    if [[ -d /etc/cloud ]]; then
        mkdir -p /etc/cloud/cloud.cfg.d
        printf 'preserve_hostname: true\n' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
        ok "cloud-init told to preserve the hostname across reboots"
    fi
}

update_system() {
    step "Updating the system"
    apt_get update
    log "running dist-upgrade (this is the slow part)…"
    apt_get dist-upgrade
    ok "system upgraded"

    log "installing base packages…"
    apt_get install ca-certificates curl gnupg git zsh unzip tar
    ok "curl, git, zsh, unzip and friends installed"
}

# Marks the core set manual so removing the Ubuntu metapackages later cannot make
# it look like an unused dependency.
protect_core_packages() {
    local keep=(
        openssh-server openssh-client openssh-sftp-server sudo cloud-init netplan.io ifupdown
        systemd systemd-sysv systemd-resolved dbus rsyslog cron ufw unattended-upgrades
        ca-certificates curl wget gnupg git zsh unzip tar less nano vim-tiny
        iproute2 iputils-ping net-tools initramfs-tools e2fsprogs
        linux-generic linux-image-generic linux-image-virtual linux-virtual
        grub-pc grub-efi-amd64 grub2-common software-properties-common
    )
    local present=() p
    for p in "${keep[@]}"; do
        if pkg_installed "$p"; then present+=("$p"); fi
    done
    if [[ ${#present[@]} -gt 0 ]]; then
        apt-mark manual "${present[@]}" >/dev/null 2>&1 || true
        ok "core packages pinned as manually installed (${#present[@]} of them)"
    fi
}

remove_snap() {
    local pass snaps=() name

    if command -v snap >/dev/null 2>&1; then
        log "removing installed snaps…"
        for pass in 1 2 3; do
            mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR>1 {print $1}' || true)
            [[ ${#snaps[@]} -gt 0 ]] || break
            # apps first, then bases/core/snapd — snapd refuses to drop a base still in use
            for name in "${snaps[@]}"; do
                case "$name" in core*|snapd|bare) continue ;; esac
                timeout 180 snap remove --purge "$name" >/dev/null 2>&1 || true
            done
            for name in "${snaps[@]}"; do
                case "$name" in
                    core*|snapd|bare) timeout 180 snap remove --purge "$name" >/dev/null 2>&1 || true ;;
                esac
            done
        done
    fi

    sysd disable --now snapd.service
    sysd disable --now snapd.socket
    sysd disable --now snapd.seeded.service
    sysd disable --now snapd.snap-repair.timer

    purge_if_installed snapd
    apt-mark hold snapd >/dev/null 2>&1 || true

    # Negative pin so nothing can pull snapd back in as a dependency.
    cat > /etc/apt/preferences.d/no-snap.pref <<'EOF'
# Installed by setup-vps.sh — keep snapd off this machine.
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /root/snap
    ok "snap removed, held and pinned (lxd and other snap-backed packages will now refuse to install — intended)"
}

remove_telemetry() {
    purge_if_installed popularity-contest ubuntu-report apport apport-symptoms whoopsie
    if [[ -f /etc/default/apport ]]; then
        sed -i 's/^enabled=.*/enabled=0/' /etc/default/apport
    fi
    sysd disable --now apport.service
    sysd disable --now whoopsie.service
    purge_if_installed landscape-common landscape-client
    ok "crash reporting, popcon and Landscape removed"
}

remove_motd_ads() {
    local f
    if [[ -f /etc/default/motd-news ]]; then
        sed -i 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news
    fi
    sysd disable --now motd-news.timer
    sysd disable --now motd-news.service

    for f in 10-help-text 50-motd-news 80-livepatch 88-esm-announce \
             91-contract-ua-esm-status 91-release-upgrade 95-hwe-eol; do
        if [[ -f "/etc/update-motd.d/$f" ]]; then
            chmod -x "/etc/update-motd.d/$f" || true
        fi
    done
    ok "MOTD news, livepatch/ESM announcements and upgrade nags disabled"
}

remove_ubuntu_pro() {
    local candidates=(ubuntu-advantage-tools ubuntu-pro-client ubuntu-advantage-desktop-daemon ubuntu-pro-auto-attach)
    local present=() p removals bad

    for p in "${candidates[@]}"; do
        if pkg_installed "$p"; then present+=("$p"); fi
    done
    if [[ ${#present[@]} -eq 0 ]]; then
        skip "Ubuntu Pro client not installed"
        return 0
    fi

    if command -v pro >/dev/null 2>&1; then
        pro config set apt_news=false >/dev/null 2>&1 || true
    fi

    # Dry run first — this purge drops ubuntu-minimal/ubuntu-server, so make very
    # sure it is not about to take sshd or the kernel with it.
    removals="$(would_remove purge "${present[@]}")"
    bad="$(protected_hits "$removals")"
    if [[ -n "$bad" ]]; then
        warn "skipped Ubuntu Pro removal — it would also remove:$bad"
        return 0
    fi

    purge_if_installed "${present[@]}"
    rm -f /etc/apt/apt.conf.d/20apt-esm-hook.conf
    ok "Ubuntu Pro / ESM advertising removed (the ubuntu-minimal metapackage goes with it — harmless)"
}

debloat() {
    if [[ "$IS_UBUNTU" != true ]]; then
        step "De-bloat"; skip "skipped (not Ubuntu)"; return 0
    fi
    if [[ "$DO_DEBLOAT" != true ]]; then
        step "De-bloat"; skip "skipped (--no-debloat)"; return 0
    fi

    step "Removing snap and Ubuntu bloat"
    protect_core_packages
    remove_snap
    remove_telemetry
    remove_motd_ads
    remove_ubuntu_pro
}

install_omz() {
    step "Installing Oh My Zsh"

    if [[ -d "$OMZ_DIR" ]]; then
        skip "Oh My Zsh already present"
    else
        env HOME=/root USER=root LOGNAME=root SHELL=/bin/bash RUNZSH=no CHSH=no KEEP_ZSHRC=no \
            sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        ok "Oh My Zsh installed"
    fi
    [[ -f "$ZSHRC" ]] || die "Oh My Zsh did not create $ZSHRC"

    local name url
    mkdir -p "$OMZ_CUSTOM/plugins"
    for name in zsh-autosuggestions zsh-syntax-highlighting; do
        url="https://github.com/zsh-users/${name}.git"
        if [[ -d "$OMZ_CUSTOM/plugins/$name/.git" ]]; then
            git -C "$OMZ_CUSTOM/plugins/$name" pull --ff-only --quiet || warn "could not update $name"
            skip "$name already installed"
        else
            git clone --depth=1 --quiet "$url" "$OMZ_CUSTOM/plugins/$name"
            ok "$name installed"
        fi
    done

    # zsh-syntax-highlighting must stay last — it wraps the ZLE widgets the others register.
    if grep -qE '^[[:space:]]*plugins=\(' "$ZSHRC"; then
        sed -i -E "s|^[[:space:]]*plugins=\(.*\)[[:space:]]*$|plugins=($OMZ_PLUGINS)|" "$ZSHRC"
    else
        printf 'plugins=(%s)\n' "$OMZ_PLUGINS" >> "$ZSHRC"
    fi
    if grep -qE "^plugins=\(${OMZ_PLUGINS// /[[:space:]]}\)$" "$ZSHRC"; then
        ok "plugins: $OMZ_PLUGINS"
    else
        warn "could not rewrite the plugins=() line — set it by hand in $ZSHRC to: plugins=($OMZ_PLUGINS)"
    fi
}

install_zoxide() {
    if [[ "$INSTALL_ZOXIDE" != true ]]; then
        step "zoxide"; skip "skipped"; return 0
    fi
    step "Installing zoxide"
    if command -v zoxide >/dev/null 2>&1 || [[ -x /root/.local/bin/zoxide ]]; then
        skip "zoxide already installed"
        return 0
    fi

    # The upstream installer keeps us on a modern release; distro packages lag badly.
    if as_root_home sh -c 'curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh' >/dev/null 2>&1 \
       && [[ -x /root/.local/bin/zoxide ]]; then
        ok "zoxide $(/root/.local/bin/zoxide --version 2>/dev/null | awk '{print $2}') installed to /root/.local/bin"
    elif apt_get install zoxide; then
        ok "zoxide installed from apt"
    else
        warn "zoxide installation failed"
    fi
}

install_docker() {
    if [[ "$INSTALL_DOCKER" != true ]]; then
        step "Docker"; skip "skipped"; return 0
    fi
    step "Installing Docker and the Compose plugin"

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        skip "Docker and Compose already installed"
    else
        purge_if_installed docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc

        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
            "$(dpkg --print-architecture)" "$DOCKER_DISTRO" "$DOCKER_CODENAME" \
            > /etc/apt/sources.list.d/docker.list

        apt_get update
        apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    sysd enable --now containerd.service
    sysd enable --now docker.service

    if docker --version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        ok "$(docker --version)"
        ok "$(docker compose version)"
    else
        warn "Docker installed but the version check failed — check 'systemctl status docker'"
    fi
}

install_bun() {
    if [[ "$INSTALL_BUN" != true ]]; then
        step "Bun"; skip "skipped"; return 0
    fi
    step "Installing Bun"

    if [[ -x /root/.bun/bin/bun ]]; then
        skip "Bun already installed ($(/root/.bun/bin/bun --version 2>/dev/null))"
        return 0
    fi

    pkg_installed unzip || apt_get install unzip
    if as_root_home bash -c 'curl -fsSL https://bun.sh/install | bash' >/dev/null 2>&1 && [[ -x /root/.bun/bin/bun ]]; then
        ok "bun $(/root/.bun/bin/bun --version)"
    else
        warn "Bun installation failed — retry later with: curl -fsSL https://bun.sh/install | bash"
    fi
}

write_zshrc_block() {
    step "Wiring up .zshrc"

    # Drop the previous block first so re-runs never stack duplicates.
    sed -i "\|^${BLOCK_START}$|,\|^${BLOCK_END}$|d" "$ZSHRC"

    cat >> "$ZSHRC" <<EOF
${BLOCK_START}
# Managed by setup-vps.sh — edits inside this block are overwritten on re-run.
export PATH="\$HOME/.local/bin:\$PATH"

# bun
export BUN_INSTALL="\$HOME/.bun"
[ -d "\$BUN_INSTALL/bin" ] && export PATH="\$BUN_INSTALL/bin:\$PATH"
[ -s "\$BUN_INSTALL/_bun" ] && source "\$BUN_INSTALL/_bun"
EOF

    if [[ "$INSTALL_ZOXIDE" == true ]]; then
        cat >> "$ZSHRC" <<EOF

# zoxide — 'z <dir>' to jump around, 'zi' for the interactive picker
command -v zoxide >/dev/null 2>&1 && eval "\$(zoxide init zsh)"
EOF
    fi

    printf '%s\n' "$BLOCK_END" >> "$ZSHRC"
    if [[ "$INSTALL_ZOXIDE" == true ]]; then
        ok "PATH, bun and zoxide init appended to $ZSHRC"
    else
        ok "PATH and bun init appended to $ZSHRC"
    fi
}

set_default_shell() {
    step "Making zsh root's login shell"
    local zsh_bin
    zsh_bin="$(command -v zsh || true)"
    if [[ -z "$zsh_bin" ]]; then
        warn "zsh not found — login shell unchanged"
        return 0
    fi

    grep -qxF "$zsh_bin" /etc/shells || printf '%s\n' "$zsh_bin" >> /etc/shells

    if chsh -s "$zsh_bin" root >/dev/null 2>&1 || usermod -s "$zsh_bin" root >/dev/null 2>&1; then
        ok "root's shell is now $(getent passwd root | cut -d: -f7)"
    else
        warn "could not change root's shell — run: chsh -s $zsh_bin root"
    fi
}

cleanup() {
    step "Cleaning up"

    local removals bad
    removals="$(would_remove autoremove --purge)"
    if [[ -z "$removals" ]]; then
        skip "nothing to autoremove"
    else
        bad="$(protected_hits "$removals")"
        if [[ -n "$bad" ]]; then
            warn "skipped autoremove — it wanted to remove:$bad (review with 'apt autoremove' yourself)"
        else
            apt_get autoremove --purge || warn "autoremove failed"
            ok "removed orphaned packages"
        fi
    fi

    apt_get autoclean || true
    apt-get clean
    rm -f /root/install.sh /root/bun.zip
    if have_systemd; then
        journalctl --vacuum-time=3d >/dev/null 2>&1 || true
    fi
    ok "apt caches cleared"
}

summary() {
    local shell_now zsh_v zoxide_v docker_v compose_v bun_v
    shell_now="$(getent passwd root | cut -d: -f7)"
    zsh_v="$(zsh --version 2>/dev/null | head -n1 || true)"
    zoxide_v="$(zoxide --version 2>/dev/null || /root/.local/bin/zoxide --version 2>/dev/null || true)"
    docker_v="$(docker --version 2>/dev/null || true)"
    compose_v="$(docker compose version --short 2>/dev/null || true)"
    bun_v="$(/root/.bun/bin/bun --version 2>/dev/null || true)"

    printf '\n%s────────────────────────────────────────────%s\n' "$C_GREEN" "$C_RESET"
    printf '%s Done%s — %s\n' "$C_GREEN" "$C_RESET" "$DISTRO_NAME"
    printf '%s────────────────────────────────────────────%s\n' "$C_GREEN" "$C_RESET"
    printf '  hostname : %s\n' "$(hostname 2>/dev/null || cat /etc/hostname)"
    printf '  shell    : %s\n' "$shell_now"
    printf '  zsh      : %s\n' "${zsh_v:-not installed}"
    printf '  zoxide   : %s\n' "${zoxide_v:-not installed}"
    printf '  docker   : %s\n' "${docker_v:-not installed}"
    printf '  compose  : %s\n' "${compose_v:-not installed}"
    printf '  bun      : %s\n' "${bun_v:-not installed}"

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf '\n%sWarnings (%d):%s\n' "$C_YELLOW" "${#WARNINGS[@]}" "$C_RESET"
        printf '  - %s\n' "${WARNINGS[@]}"
    fi

    printf '\nStart using zsh now:  %sexec zsh%s   (or log out and back in)\n' "$C_BLUE" "$C_RESET"
    if [[ -f /var/run/reboot-required ]]; then
        printf '%sA reboot is required%s to finish the upgrade.\n' "$C_YELLOW" "$C_RESET"
    else
        printf 'A reboot is recommended after a full system upgrade.\n'
    fi
    [[ -n "$LOG" ]] && printf '%sLog: %s%s\n' "$C_DIM" "$LOG" "$C_RESET"
    return 0
}

main() {
    parse_args "$@"
    detect_distro

    printf '\n%s╭──────────────────────────────────────────╮%s\n' "$C_BLUE" "$C_RESET"
    printf '%s│  fresh VPS setup                         │%s\n' "$C_BLUE" "$C_RESET"
    printf '%s╰──────────────────────────────────────────╯%s\n' "$C_BLUE" "$C_RESET"

    gather_answers

    # Logging starts only now, so the prompts above are not swallowed by tee's buffer.
    LOG="/var/log/vps-setup-$(date +%F-%H%M%S).log"
    exec > >(tee -a "$LOG") 2>&1

    set_hostname
    update_system
    debloat
    install_omz
    install_zoxide
    install_docker
    install_bun
    write_zshrc_block
    set_default_shell
    cleanup
    summary
}

main "$@"
