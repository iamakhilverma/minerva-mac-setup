#!/bin/zsh
# Manage a FUSE-T sshfs mount of a Minerva (Sinai HPC) path at a local mountpoint.
# PORTABLE version: all per-user settings come from a config file, so this script
# is identical on every machine. Installed by minerva-setup.sh.
#
# Config (sourced): $MINERVA_CONFIG or ~/.config/minerva/minerva.conf, providing
#   MINERVA_MOUNT        local mountpoint            (default ~/minerva)
#   MINERVA_REMOTE_PATH  remote path on Minerva      (default "" = your home dir)
#   MINERVA_NODES        login-node preference list  (default minerva13 11 12 14 minerva)
#   MINERVA_LOG          log file                    (default ~/Library/Logs/minerva-mount.log)
#   MINERVA_SSHFS        path to sshfs               (default: auto-detected)
#
# Subcommands:
#   minerva-mount.sh [mount]   mount (or repair) the mountpoint  (default)
#   minerva-mount.sh status    report state — READ ONLY, never touches the mount, never hangs
#   minerva-mount.sh clear     force-unmount + kill our daemons — idempotent, watchdogged
#
# Why this is more than a one-line sshfs:
#   * `minerva` is a load-balanced alias -> a bare `sshfs minerva:` lands on a
#     RANDOM login node. Minerva needs SSO password + MFA, so sshfs can only
#     connect non-interactively when a live SSH ControlMaster already exists for
#     that exact node. Gambling on the alias causes "phantom" mounts (auth hangs
#     -> zombie sshfs/go-nfsv4 -> Finder "server will not allow additional users").
#   * So we PIN to a node that already has a live master (auto-detected) and wrap
#     sshfs in a hard timeout so a hung auth can't create a phantom.
#   * If NO live master exists, we bail cleanly: mounting is on-demand by design
#     (we can't satisfy MFA from a background job). Log in first, then mount.
#
# A "phantom" = the kernel still lists the mount but it no longer works. NEVER
# reboot to clear one -- `clear` does it safely. The trap is *diagnosing* it: any
# read INTO the mount can hang in uninterruptible sleep and wedge Finder/your
# shell. So status/clear judge state from the mount table + daemon liveness +
# the bound node's SSH master ONLY (none of which touch the filesystem).
set -u

CONFIG="${MINERVA_CONFIG:-$HOME/.config/minerva/minerva.conf}"
[[ -r "$CONFIG" ]] && source "$CONFIG"

MOUNT="${MINERVA_MOUNT:-$HOME/minerva}"
REMOTE_PATH="${MINERVA_REMOTE_PATH:-}"
LOG="${MINERVA_LOG:-$HOME/Library/Logs/minerva-mount.log}"
CANDIDATES=( "${MINERVA_NODES[@]}" )
(( ${#CANDIDATES[@]} )) || CANDIDATES=(minerva13 minerva11 minerva12 minerva14 minerva)
MOUNT_TIMEOUT=20   # seconds; sshfs must establish the mount within this window
CLEAR_TIMEOUT=15   # seconds; a single unmount attempt must return within this

# Locate sshfs across Homebrew layouts (Apple Silicon /opt/homebrew, Intel /usr/local).
SSHFS="${MINERVA_SSHFS:-}"
if [[ -z "$SSHFS" || ! -x "$SSHFS" ]]; then SSHFS="$(command -v sshfs 2>/dev/null)"; fi
if [[ -z "$SSHFS" ]]; then
  for p in /opt/homebrew/bin/sshfs /usr/local/bin/sshfs; do [[ -x "$p" ]] && { SSHFS="$p"; break; }; done
fi

MODE="${1:-mount}"
mkdir -p "$MOUNT" "$(dirname "$LOG")"

log_line() { print -- "$@" >>"$LOG"; }
say()      { print -- "$@"; print -- "$@" >>"$LOG"; }

kill_orphans() {
  pkill -9 -f "sshfs .*${MOUNT}"    2>/dev/null
  pkill -9 -f "go-nfsv4 .*${MOUNT}" 2>/dev/null
}
orphan_daemons_exist() {
  pgrep -f "go-nfsv4 .*$MOUNT" >/dev/null 2>&1 || pgrep -f "sshfs .*$MOUNT" >/dev/null 2>&1
}

# The login node sshfs is bound to (parsed from its process args), or empty.
# sshfs multiplexes on that node's SSH ControlMaster, so the master's liveness
# == the mount's connection liveness.
bound_node() {
  local pid; pid=$(pgrep -f "sshfs .*$MOUNT" 2>/dev/null | head -1)
  [[ -n "$pid" ]] || return
  ps -p "$pid" -o args= 2>/dev/null | grep -oE '[A-Za-z0-9._-]+:/?' | head -1 | sed 's,:/*$,,'
}

# Echo the mount state code WITHOUT mutating anything:
#   1 = not mounted
#   2 = mounted-but-stale (phantom), via any of three failure modes:
#       (a) daemon dead        -> uncached I/O HANGS;  caught by daemon liveness
#       (b) connection severed -> uncached I/O EIO while cached attrs look fine;
#                                 caught by the bound node's master liveness, NOT
#                                 by stat (which lies "healthy" from cache)
#       (c) daemon wedged      -> caught by the final watchdogged stat (it hangs)
#   0 = mounted & responsive
probe_state() {
  mount | grep -q " on $MOUNT " || { echo 1; return; }
  if ! orphan_daemons_exist; then echo 2; return; fi          # (a)
  local node; node=$(bound_node)                               # (b)
  if [[ -n "$node" ]] && ! ssh -O check "$node" >/dev/null 2>&1; then echo 2; return; fi
  ( stat "$MOUNT" >/dev/null 2>&1 ) &                          # (c)
  local pid=$! i=0
  while (( i < 6 )); do
    sleep 0.5
    if ! kill -0 $pid 2>/dev/null; then wait $pid 2>/dev/null; echo 0; return; fi
    (( i++ ))
  done
  kill -9 $pid 2>/dev/null
  echo 2
}

# Force-unmount under a watchdog so a hung diskutil can't block us forever.
force_unmount() {
  diskutil unmount force "$MOUNT" >>"$LOG" 2>&1 &
  local pid=$! i=0
  while (( i < CLEAR_TIMEOUT )); do
    sleep 1
    if ! kill -0 $pid 2>/dev/null; then wait $pid 2>/dev/null; return 0; fi
    (( i++ ))
  done
  kill -9 $pid 2>/dev/null
  log_line "  diskutil unmount force timed out after ${CLEAR_TIMEOUT}s; trying umount -f"
  umount -f "$MOUNT" >>"$LOG" 2>&1
}

# First login node with a live ControlMaster (passwordless, no MFA).
live_master() {
  local h
  for h in $CANDIDATES; do
    if ssh -O check "$h" >/dev/null 2>&1; then echo "$h"; return 0; fi
  done
  return 1
}

# --------------------------------------------------------------------------- #
if [[ "$MODE" == "status" ]]; then
  st=$(probe_state)
  daemons=$(pgrep -fl 'go-nfsv4|sshfs' 2>/dev/null | grep "$MOUNT" || echo "(none)")
  bnode=$(bound_node)
  master=$(live_master || echo "")
  print -- "=== minerva mount status ==="
  print -- "mountpoint:      $MOUNT"
  case $st in
    0) print -- "state:           HEALTHY (mounted, daemon + connection alive)" ;;
    1) print -- "state:           NOT MOUNTED" ;;
    2) print -- "state:           PHANTOM/STALE  ->  run: minerva-clear" ;;
  esac
  print -- "our daemons:     $daemons"
  if [[ -n "$bnode" ]]; then
    if ssh -O check "$bnode" >/dev/null 2>&1; then
      print -- "sshfs bound to:  $bnode (its master is LIVE — connection up)"
    else
      print -- "sshfs bound to:  $bnode (its master is DEAD — connection severed)"
    fi
  fi
  if [[ -n "$master" ]]; then
    print -- "live SSH master: $master  (available for minerva-mount)"
  else
    print -- "live SSH master: none  (log into a node first, e.g. \`minerva13\`)"
  fi
  log_line "--- status -> state=$st bound=${bnode:-none} master=${master:-none} ---"
  exit 0
fi

if [[ "$MODE" == "clear" ]]; then
  log_line "--- clear ---"
  st=$(probe_state)
  case $st in
    1) say "not mounted." ;;
    0) say "healthy mount present; force-unmounting on request." ; force_unmount ;;
    2) say "phantom/stale mount; force-unmounting." ; force_unmount ;;
  esac
  if orphan_daemons_exist; then say "reaping orphan daemons."; kill_orphans; fi
  if mount | grep -q " on $MOUNT "; then
    say "WARNING: still in mount table after clear — try again, or reboot as last resort."
    exit 1
  fi
  say "clear OK — $MOUNT is unmounted. Remount with: minerva-mount"
  exit 0
fi

# mount (default) — all output to the log.
exec >>"$LOG" 2>&1
print -- "--- $(date '+%Y-%m-%d %H:%M:%S') minerva-mount.sh ---"

if [[ -z "$SSHFS" ]]; then
  print -- "ERROR: sshfs not found. Install it:  brew tap macos-fuse-t/cask && brew install --cask fuse-t fuse-t-sshfs"
  exit 1
fi

case "$(probe_state)" in
  0) print -- "already mounted and responsive, nothing to do."; exit 0 ;;
  2) print -- "stale/phantom mount detected, force-unmounting + clearing daemons"
     force_unmount; kill_orphans ;;
  1) if orphan_daemons_exist; then print -- "orphaned daemons with no live mount; clearing"; kill_orphans; fi ;;
esac

NODE="$(live_master || true)"
if [[ -z "$NODE" ]]; then
  print -- "no live Minerva SSH master; skipping mount (on-demand by design)."
  print -- "  -> log into a node first (e.g. \`minerva13\`), then run: minerva-mount"
  exit 0
fi
print -- "mounting via live master on $NODE (remote: '${REMOTE_PATH:-<home>}')"

"$SSHFS" "${NODE}:${REMOTE_PATH}" "$MOUNT" \
  -o reconnect \
  -o defer_permissions \
  -o noappledouble \
  -o volname=minerva \
  -o cache=yes \
  -o cache_timeout=300 \
  -o cache_stat_timeout=300 \
  -o cache_dir_timeout=300 \
  -o cache_link_timeout=300 \
  -o Compression=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 &
sshpid=$!
( sleep $MOUNT_TIMEOUT; kill -9 $sshpid 2>/dev/null ) &
watch=$!
wait $sshpid 2>/dev/null; rc=$?
kill $watch 2>/dev/null

if mount | grep -q " on $MOUNT "; then
  print -- "mount OK via $NODE (sshfs rc=$rc)"; exit 0
else
  print -- "mount FAILED via $NODE (sshfs rc=$rc); clearing orphans"; kill_orphans; exit 1
fi
