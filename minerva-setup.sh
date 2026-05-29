#!/usr/bin/env bash
# minerva-setup.sh — set up Minerva (Sinai HPC) convenience tooling on a Mac.
#
# Installs, for the CURRENT user (prompts for their own credentials):
#   * sshpass + FUSE-T (via Homebrew; Apple Silicon and Intel both supported)
#   * ~/.ssh/config block: host aliases minerva, minerva11..14; X11; an N-hour
#     passwordless ControlMaster window
#   * ~/.minerva_password (mode 0600) — their SSO password, fed to logins by sshpass
#   * ~/.config/minerva/minerva.conf — all tunable settings
#   * ~/bin/minerva-mount.sh — the on-demand FUSE-T mount manager
#   * ~/.zshrc block: minerva / minerva11..14 (login), minerva-mount/-status/-clear,
#     rsync helpers (mpull/mpush/mput/mget), minerva-update-password
#
# Idempotent: re-running replaces the managed blocks in place. Settings can be
# accepted as defaults; credentials are always prompted (never hard-coded).
#
# Usage:   ./minerva-setup.sh            # interactive
#          ./minerva-setup.sh --defaults # accept all defaults except credentials
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BEGIN="# >>> minerva-setup >>>"
END="# <<< minerva-setup <<<"
USE_DEFAULTS=0
[[ "${1:-}" == "--defaults" || "${1:-}" == "-y" ]] && USE_DEFAULTS=1

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" "default"  — sets VAR. In --defaults mode, always takes the
# default (even an empty one) without prompting. Otherwise prompts, falling back
# to the default on empty input. (Required fields like username are read directly.)
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __reply=""
  if (( USE_DEFAULTS )); then printf -v "$__var" '%s' "$__default"; return; fi
  if [[ -n "$__default" ]]; then read -r -p "$__prompt [$__default]: " __reply || true
  else                            read -r -p "$__prompt: " __reply || true; fi
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

# Replace (or append) the managed block in a file, atomically.
write_block() {
  local file="$1" content="$2" tmp
  touch "$file"; tmp="$(mktemp)"
  awk -v b="$BEGIN" -v e="$END" 'BEGIN{s=0} $0==b{s=1;next} $0==e{s=0;next} !s{print}' "$file" >"$tmp"
  { cat "$tmp"; printf '%s\n%s\n%s\n' "$BEGIN" "$content" "$END"; } >"$file.new"
  mv "$file.new" "$file"; rm -f "$tmp"
}

bold "Minerva setup"
echo

# ---- preflight --------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This installer is for macOS."
if ! command -v brew >/dev/null 2>&1; then
  die "Homebrew not found. Install it first:
     /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
   then re-run this script."
fi
BREW_PREFIX="$(brew --prefix)"
ok "Homebrew at $BREW_PREFIX ($(uname -m))"
[[ -f "$SCRIPT_DIR/minerva-mount.sh" ]] || die "minerva-mount.sh not found next to this script ($SCRIPT_DIR)."

# ---- prompts ----------------------------------------------------------------
echo; bold "Your Minerva account"
read -r -p "Sinai HPC username (e.g. smithj01): " MUSER || true   # required in all modes
[[ -n "$MUSER" ]] || die "Username is required."

# Password (always prompted; never defaulted). Entered twice, hidden.
PWFILE="$HOME/.minerva_password"
if (( USE_DEFAULTS )) && [[ -s "$PWFILE" ]]; then
  ok "Keeping existing password file ($PWFILE)"
else
  while :; do
    read -r -s -p "Sinai SSO password: " PW1; echo
    read -r -s -p "Confirm password:   " PW2; echo
    [[ -n "$PW1" ]] || { warn "Empty — try again."; continue; }
    [[ "$PW1" == "$PW2" ]] || { warn "Did not match — try again."; continue; }
    break
  done
fi

echo; bold "Settings (press Enter to accept the recommended default)"
ask MMOUNT  "Local mountpoint" "$HOME/minerva"
ask MREMOTE "Remote path to mount (blank = your Minerva home directory)" ""
ask MPERSIST "Keep the login alive (passwordless) for how many hours" "8"
[[ "$MPERSIST" =~ ^[0-9]+$ ]] || die "Hours must be a whole number (got '$MPERSIST')."

echo; bold "About to apply:"
info "username:        $MUSER"
info "password file:   $PWFILE (mode 0600, stays only on this Mac)"
info "mountpoint:      $MMOUNT"
info "remote path:     ${MREMOTE:-<your Minerva home>}"
info "login persists:  ${MPERSIST}h"
info "files touched:   ~/.ssh/config, ~/.zshrc, ~/bin/minerva-mount.sh, ~/.config/minerva/minerva.conf"
if (( ! USE_DEFAULTS )); then
  read -r -p "Proceed? [Y/n]: " GO || true
  [[ "${GO:-Y}" =~ ^[Yy]?$ ]] || die "Aborted."
fi

# ---- dependencies -----------------------------------------------------------
echo; bold "Installing dependencies"
HAVE_SSHPASS=0
if command -v sshpass >/dev/null 2>&1; then HAVE_SSHPASS=1; ok "sshpass present"
else
  info "installing sshpass…"
  # sshpass is now in homebrew-core; older Homebrew needs a tap. Try core first.
  if brew install sshpass 2>/dev/null \
     || brew install hudochenkov/sshpass/sshpass 2>/dev/null \
     || brew install esolitos/ipa/sshpass 2>/dev/null; then
    HAVE_SSHPASS=1; ok "sshpass installed"
  else
    warn "Could not install sshpass automatically — continuing without it."
    warn "Logins will prompt for your password (you still type it only once per"
    warn "${MPERSIST}h ControlMaster window). To enable auto-fill later:"
    warn "  brew install sshpass   # then re-run ./minerva-setup.sh"
  fi
fi
if command -v sshfs >/dev/null 2>&1 || [[ -x "$BREW_PREFIX/bin/sshfs" ]]; then ok "FUSE-T sshfs present"
else
  info "installing FUSE-T (may prompt for your Mac password / a macOS approval)…"
  brew tap macos-fuse-t/cask >/dev/null 2>&1 || true
  brew install --cask fuse-t fuse-t-sshfs || die "FUSE-T install failed. Install it manually, then re-run."
  ok "FUSE-T installed"
fi

# ---- secrets ----------------------------------------------------------------
echo; bold "Writing config"
if [[ -n "${PW1:-}" ]]; then
  ( umask 077; printf '%s\n' "$PW1" >"$PWFILE" ); chmod 600 "$PWFILE"
  ok "password saved to $PWFILE (0600)"
fi
unset PW1 PW2 || true

# ---- config file ------------------------------------------------------------
mkdir -p "$HOME/.config/minerva" "$HOME/bin" "$HOME/.ssh/sockets" "$MMOUNT"
chmod 700 "$HOME/.ssh/sockets"
cat >"$HOME/.config/minerva/minerva.conf" <<EOF
# Minerva tooling settings — edit freely, then open a new shell.
MINERVA_USER="$MUSER"
MINERVA_MOUNT="$MMOUNT"
MINERVA_REMOTE_PATH="$MREMOTE"
MINERVA_NODES=(minerva13 minerva11 minerva12 minerva14 minerva)
MINERVA_LOG="\$HOME/Library/Logs/minerva-mount.log"
MINERVA_PWFILE="$PWFILE"
EOF
ok "wrote ~/.config/minerva/minerva.conf"

# ---- mount script -----------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/minerva-mount.sh" "$HOME/bin/minerva-mount.sh"
ok "installed ~/bin/minerva-mount.sh"

# ---- ssh config -------------------------------------------------------------
SSH_BLOCK="# Minerva (Sinai HPC) — managed by minerva-setup.sh
Host minerva minerva11 minerva12 minerva13 minerva14
    HostName %h.hpc.mssm.edu
Host minerva*
    User $MUSER
    ForwardX11 yes
    ForwardX11Trusted yes
    PreferredAuthentications keyboard-interactive,password
    NumberOfPasswordPrompts 2
    PasswordAuthentication yes
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist ${MPERSIST}h"
write_block "$HOME/.ssh/config" "$SSH_BLOCK"; chmod 600 "$HOME/.ssh/config"
ok "updated ~/.ssh/config (User $MUSER, ControlPersist ${MPERSIST}h)"

# ---- zshrc ------------------------------------------------------------------
# Login aliases: with sshpass the password is auto-fed; without it you just type
# it (once per ControlMaster window). MFA push is approved on your phone either way.
if (( HAVE_SSHPASS )); then
  LOGIN_ALIASES="# Log in (password auto-fed via sshpass; approve the MFA push on your phone).
alias minerva='sshpass -f \"\$MINERVA_PWFILE\" ssh -Y minerva'
alias minerva11='sshpass -f \"\$MINERVA_PWFILE\" ssh -Y minerva11'
alias minerva12='sshpass -f \"\$MINERVA_PWFILE\" ssh -Y minerva12'
alias minerva13='sshpass -f \"\$MINERVA_PWFILE\" ssh -Y minerva13'
alias minerva14='sshpass -f \"\$MINERVA_PWFILE\" ssh -Y minerva14'"
else
  LOGIN_ALIASES="# Log in (type your password when asked — once per ControlMaster window; then MFA).
alias minerva='ssh -Y minerva'
alias minerva11='ssh -Y minerva11'
alias minerva12='ssh -Y minerva12'
alias minerva13='ssh -Y minerva13'
alias minerva14='ssh -Y minerva14'"
fi
ZSHRC_BLOCK="# Minerva (Sinai HPC) — managed by minerva-setup.sh. Settings: ~/.config/minerva/minerva.conf
[ -r \"\$HOME/.config/minerva/minerva.conf\" ] && source \"\$HOME/.config/minerva/minerva.conf\"
: \"\${MINERVA_PWFILE:=\$HOME/.minerva_password}\"

$LOGIN_ALIASES

# Mount management (on-demand — run AFTER you've logged into a node).
alias minerva-mount=\"\$HOME/bin/minerva-mount.sh\"
alias minerva-status=\"\$HOME/bin/minerva-mount.sh status\"
alias minerva-clear=\"\$HOME/bin/minerva-mount.sh clear\"

# rsync/scp helpers against your Minerva tree (reuse the live master, no extra auth).
MINERVA_BASE=\"minerva:\${MINERVA_REMOTE_PATH:-.}\"
mpull() { rsync -avh --progress \"\$MINERVA_BASE/\$1\" \"\$2\"; }
mpush() { rsync -avh --progress \"\$1\" \"\$MINERVA_BASE/\$2\"; }
alias mput='scp -r'
alias mget='scp -r'

minerva-update-password() {
  local newpw
  printf 'New Minerva password: '; read -rs newpw; printf '\\n'
  [ -z \"\$newpw\" ] && { echo 'Aborted (empty).'; return 1; }
  ( umask 077; printf '%s\\n' \"\$newpw\" > \"\$MINERVA_PWFILE\" ); chmod 600 \"\$MINERVA_PWFILE\"
  echo \"Updated \$MINERVA_PWFILE.\"
}"
write_block "$HOME/.zshrc" "$ZSHRC_BLOCK"
ok "updated ~/.zshrc"

# ---- verify -----------------------------------------------------------------
echo; bold "Verifying"
ssh -G minerva 2>/dev/null | grep -qi "user $MUSER" && ok "ssh resolves minerva -> user $MUSER" || warn "ssh config not picked up yet (open a new shell)"
"$HOME/bin/minerva-mount.sh" status >/dev/null 2>&1 && ok "minerva-mount.sh runs" || warn "minerva-mount.sh status returned nonzero (fine if not yet mounted)"

echo
bold "Done. Next steps:"
info "1. Open a new terminal tab  (or:  source ~/.zshrc)"
info "2. Log in:    minerva13      → approve the MFA push on your phone"
info "3. Mount:     minerva-mount"
info "4. Check:     minerva-status   (HEALTHY?)  •  browse ~/minerva in Finder"
echo
info "Diagnose anytime: minerva-status   •   Recover a wedged mount: minerva-clear"
info "Change settings:  edit ~/.config/minerva/minerva.conf   •   New password: minerva-update-password"
