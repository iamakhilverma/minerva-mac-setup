# minerva-mac-setup

One-command setup for **Minerva (Sinai HPC)** on macOS — Apple Silicon or Intel.
It prompts **you** for your own username and password (nothing is baked in), then
wires up logins, a long-lived passwordless session, and an on-demand Finder mount.

## What you get

- `minerva`, `minerva11`–`minerva14` — one-command SSH login (password auto-fed
  via `sshpass`; you still approve the MFA push on your phone). The first login
  opens a passwordless `ControlMaster` window (default 8h).
- `minerva-mount` / `minerva-status` / `minerva-clear` — an **on-demand** FUSE-T
  mount of your Minerva tree at `~/minerva`, with a phantom-proof health check
  (`status` never touches the filesystem, so it can't hang; `clear` recovers a
  wedged mount without a reboot).
- `mpull` / `mpush` / `mput` / `mget` — rsync/scp helpers against your tree.
- `minerva-update-password` — rotate the saved password.

## Requirements

- macOS with [Homebrew](https://brew.sh) installed. Everything else (`sshpass`,
  FUSE-T) is installed for you. FUSE-T may ask for your Mac password / a one-time
  macOS approval.
- A Sinai HPC (Minerva) account with SSO password + MFA (MS Authenticator).

## Install

```sh
git clone https://github.com/iamakhilverma/minerva-mac-setup.git
cd minerva-mac-setup
./minerva-setup.sh            # interactive — prompts for everything
# or:
./minerva-setup.sh --defaults # accept all recommended defaults (still prompts for username + password)
```

You'll be asked for (recommended defaults in brackets):

| Prompt | Default | Notes |
| --- | --- | --- |
| Sinai HPC username | — | required, e.g. `smithj01` |
| SSO password | — | entered twice, hidden; saved to `~/.minerva_password` (mode 0600) |
| Local mountpoint | `~/minerva` | where the Finder mount appears |
| Remote path | *your Minerva home* | blank = home dir; or e.g. a lab project path |
| Login persists | `8` hours | the passwordless `ControlMaster` window |

Then open a new terminal and:

```sh
minerva13        # log in, approve MFA → opens the 8h master
minerva-mount    # mount ~/minerva (reuses that master)
minerva-status   # HEALTHY?  Then browse ~/minerva in Finder.
```

## How it's wired

- **Code is identical for everyone**; only settings differ. All settings live in
  `~/.config/minerva/minerva.conf`. Edit it, open a new shell — no reinstall.
- `~/bin/minerva-mount.sh` (the mount manager) reads that config and auto-detects
  `sshfs` under either Homebrew prefix.
- The installer manages a clearly-marked block in `~/.ssh/config` and `~/.zshrc`
  (`# >>> minerva-setup >>>` … `# <<< minerva-setup <<<`). Re-running replaces just
  that block; everything else in those files is left untouched.

## Customize later

- **Any setting:** edit `~/.config/minerva/minerva.conf`, then open a new shell.
- **Persist hours / username:** re-run `./minerva-setup.sh`, or edit the
  `~/.ssh/config` block directly.
- **New password:** `minerva-update-password`.

## Security

Your password is stored at `~/.minerva_password`, readable only by you (mode 0600),
and never leaves the machine. `sshpass -f` reads it from that file (it isn't placed
in an environment variable or visible in `ps`). If you'd rather not store the
password on disk at all, delete `~/.minerva_password` and just type it at each
login — everything else still works.

## Uninstall

```sh
sed -i '' '/>>> minerva-setup >>>/,/<<< minerva-setup <<</d' ~/.zshrc ~/.ssh/config
rm -f ~/bin/minerva-mount.sh ~/.minerva_password
rm -rf ~/.config/minerva
# (optional) brew uninstall --cask fuse-t fuse-t-sshfs ; brew uninstall sshpass
```

## Troubleshoot

- *"Could not install sshpass"* → it's optional. The installer now falls back to
  plain `ssh` logins (you type your password once per session). To get auto-fill,
  run `brew install sshpass` (it's in homebrew-core now) and re-run the installer.
- `minerva-mount` says *"no live Minerva SSH master"* → log into a node first
  (`minerva13`), then `minerva-mount`. Mounting is on-demand by design.
- `~/minerva` looks stuck → `minerva-status` (safe, never hangs). If `PHANTOM`,
  run `minerva-clear`, then `minerva-mount`. You never need to reboot.
- Logs: `~/Library/Logs/minerva-mount.log`.
