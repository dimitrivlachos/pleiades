# Migrating another machine to Pleiades (agent playbook)

Operational checklist for moving a machine onto the chezmoi-managed
Pleiades config, written after doing `spark-f222` for real. This is more
prescriptive than `docs/migrating_to_chezmoi.md` and records the gotchas
that actually bit. Run it top to bottom **on the target machine**. Never
apply blind - the `chezmoi diff` and the safety checks are the point.

> To use this on another machine it has to be present there. It is
> uncommitted, so either commit it to `docs/` first (then it travels with
> the source), or paste it into the session on the target box.

## Before you start (user, out-of-band - I cannot do these)

- **Age key.** The machine needs the age identity at
  `~/.config/chezmoi/key.txt` to decrypt secrets. It comes from
  Vaultwarden and only you can put it there. Confirm it is available
  before we reach apply.
- **Specialisation.** Confirm the machine's role: `frostpaw` (personal
  workstation), `diamond` (work HPC), or `asteria` (headless server).

## 0. Pre-flight survey (read-only)

```bash
hostname; uname -m
echo "spec: ${BASH_SPECIALISATION:-<unset>}"
command -v chezmoi && chezmoi --version || echo "chezmoi not installed"
[ -f ~/.config/chezmoi/key.txt ] && echo "key present" || echo "key MISSING"
[ -e ~/.config/chezmoi/chezmoi.toml ] && echo "already init'd" || echo "fresh"
# Is it on the old install.sh layout? Survey the symlinks:
for p in ~/.bashrc_core ~/.config/tmux ~/.aider.conf.yml \
         ~/.aider.model.metadata.json ~/.ssh/config ~/.ssh/smart-proxy; do
  [ -L "$p" ] && echo "SYMLINK $p -> $(readlink "$p")"
done
find ~/.ssh -maxdepth 1 -type l -name 'id_ed25519_sk_*' | wc -l
```

## 1. Install chezmoi + init from GitHub

The repo is public on GitHub `main` now, so the clean runbook flow works
- **no local-clone seeding** like spark-f222 needed (that was only
because the branch was unmerged):

```bash
# Arch
sudo pacman -S chezmoi && chezmoi init dimitrivlachos/pleiades

# elsewhere
sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin" init dimitrivlachos/pleiades
```

- **Gotcha - the install location.** The installer's default target is
  `./bin` relative to the working directory, so from `$HOME` it lands at
  `~/bin/chezmoi`, which is on no shell's PATH. Pass `-b` or the next
  terminal reports "chezmoi: command not found".

This clones to `~/.local/share/chezmoi`, prompts for the specialisation,
and writes `~/.config/chezmoi/chezmoi.toml`. It does **not** apply and
does **not** need the key yet.

- **Gotcha - the prompt.** The specialisation uses `promptChoiceOnce`.
  In a real terminal it just asks. Running **non-interactively** (no
  TTY, e.g. an agent shell), preset it with
  `--promptChoice 'Machine specialisation=<spec>'`. The key is the
  **prompt text**, not the field name - `specialisation=<spec>` alone is
  ignored and you get `could not open a new TTY`.

## 2. Age key in place

```bash
install -m 600 -D /path/to/key.txt ~/.config/chezmoi/key.txt
chezmoi cat ~/.config/bash-config/bash_secrets.sh >/dev/null && echo "decrypts OK"
```

## 3. Preview + safety checks (read-only, BEFORE clearing or applying)

```bash
chezmoi status          # A=create M=modify D=delete; read it
chezmoi diff ~/.bashrc  # expect: only the managed block changes
chezmoi diff ~/.gitconfig   # expect: includes repoint, ~/.gitconfig.local kept
```

For a machine migrating from the old symlink layout, verify the SK key
handles are **byte-identical** before apply, or FIDO/YubiKey SSH auth
breaks (do not print key material - compare only). This has to run
**before** step 4 clears the symlinks, or the files it compares against
are already gone:

```bash
cd ~/.ssh
for f in id_ed25519_sk_*; do
  if chezmoi cat "$HOME/.ssh/$f" 2>/dev/null | cmp -s - "$f"; then
    echo "IDENTICAL $f"
  elif diff -q <(tr -d '\r' < "$f") \
               <(chezmoi cat "$HOME/.ssh/$f" | tr -d '\r') >/dev/null 2>&1; then
    echo "LINE-ENDINGS-ONLY $f"
  else
    echo "DIFFERS $f"
  fi
done
```

`IDENTICAL` means the only change is symlink -> regular file.
`LINE-ENDINGS-ONLY` is also fine and is common on the `.pub` halves:
handles written on a Windows-touched host carry CRLF and the repo has
normalised them to LF, so applying strips a stray `\r`. The private
handles are what FIDO auth actually signs with, and they should all come
back `IDENTICAL` - any `DIFFERS` there, stop and investigate before
applying.

## 4. Clear the old install.sh symlinks (only if migrating off the old layout)

chezmoi will not clean these, and one is actively dangerous: if
`~/.config/tmux` is still a symlink into the old checkout, apply writes
`tmux.conf` and the plugin externals **through** it into the old repo.
`~/.ssh/smart-proxy` points into `scripts/` in the old checkout and
carries the same hazard. Clear symlinks, guarded so a real file is never
removed:

```bash
for p in ~/.bashrc_core ~/.config/tmux ~/.aider.conf.yml \
         ~/.aider.model.metadata.json ~/.ssh/config ~/.ssh/smart-proxy; do
  [ -L "$p" ] && rm "$p" && echo "removed $p"
done
find ~/.ssh -maxdepth 1 -type l -name 'id_ed25519_sk_*' -print -delete
[ -L ~/.config/atuin/config.toml ] && rm ~/.config/atuin/config.toml
```

Confirm nothing live still points into the old checkout. `.snapshot`
hits are NetApp read-only snapshots and are not real symlinks to clear:

```bash
find ~ -maxdepth 3 -type l -lname '*/bash-config/*' | grep -v '/.snapshot/'
```

On a genuinely fresh machine (no old layout) there is nothing to clear -
those paths show up as `A` (create) in status, not `M`.

## 5. Apply

```bash
chezmoi apply --no-tty   # deploys, decrypts, fetches externals (needs network)
```

## 6. Post-apply verification

```bash
chezmoi status                                   # expect empty
stat -c '%A %n' ~/.ssh ~/.ssh/config             # 700 dir, 600 config
python3 -c "import json;json.load(open('$HOME/.config/fastfetch/config.jsonc'))" \
  && echo "fastfetch JSON ok"
[ -d ~/.config/tmux/plugins ] && echo "tmux real dir + externals"
```

## 7. Enablement (in a reloaded shell - `bc_setup_*` live there)

```bash
exec bash -l
bc_setup_ssh_agent_service   # any box with a systemd user instance
bc_setup_atuin_daemon        # frostpaw only
bc_setup_certs               # frostpaw only, needs sudo
bc_doctor                    # expect all green
```

- `exec bash -l` does **not** clear variables the old layout exported,
  and they outrank the new config: `bashrc_core` honours an existing
  `BASH_CONFIG_DIR` over its own auto-detection, so a reloaded shell
  keeps resolving into the old checkout. `ATUIN_CONFIG_DIR` is worse,
  because the new config sets it nowhere at all - it relies on atuin's
  default path - so a stale export survives untouched and atuin fails
  outright with `could not load client settings` the moment the old
  checkout goes away. Take a genuinely fresh login, or in a shell worth
  keeping:

  ```bash
  unset ATUIN_CONFIG_DIR BASH_CONFIG_DIR BASH_CONFIG_VERSION \
        SSH_AUTH_SOCK SSH_AGENT_PID
  exec bash -l
  ```

  Long-lived tmux sessions need the same treatment, and all of them do
  before the old checkout is deleted.
- `bc_setup_ssh_agent_service` is gated on systemd, not on
  specialisation: the `ssh-agent` check in `bash_doctor` fires on any
  host with a systemd user instance, Diamond workstations included.
  Enablement writes to
  `~/.config/systemd/user/default.target.wants/`, which is on the shared
  NFS home, so enabling it once covers every Diamond machine; the socket
  lives under `$XDG_RUNTIME_DIR` and stays per-machine.

- The old `bc_doctor` ssh-keys false positive (a phantom
  `id_ed25519_personal`) is already fixed in the repo, so a green sweep
  is the expectation now.
- If the legacy `id_ed25519_{d,s}` key names still exist, rename them to
  `id_ed25519_github_{d,s}` (runbook step 7). They did not on
  spark-f222, so this is often a no-op.

## Per-specialisation notes

- **frostpaw** - full stack: atuin daemon + healthcheck + linger, homelab
  CA. arm64 hosts render the `spark` fastfetch variant via
  `.chezmoi.arch`.
- **diamond** - work HPC. `bc_doctor` skips the atuin daemon and certs
  (frostpaw-gated). atuin data dir is redirected; pixi keys off
  `DIAMOND_USERNAME` in `bash_secrets.sh`. Run
  `bc_setup_ssh_agent_service` on the workstations: they do run a
  systemd user instance, so `bc_doctor` expects the unit and the
  env-file fallback is only for the bastion and compute nodes. Watch for
  no passwordless sudo and a locked-down `$HOME`.
- **asteria** - headless server (Raspberry Pi). systemd present ->
  `bc_setup_ssh_agent_service`. Gets the `atuin-homelab` config, no
  frostpaw daemon/certs.

## Gotchas log (what actually bit on spark-f222)

- `--promptChoice` key is the **prompt text** (`Machine specialisation`),
  not the field name.
- chezmoi reads its **config format from the file extension** - only
  matters if you hand-write a temp config (`.toml`), not for a normal
  `init`.
- `~/.config/tmux` symlink write-through - clear it before apply.
- SK handles show `M` in status purely because they convert
  symlink -> regular file; verify byte-identity, do not panic.
- On ws448 the `.pub` halves also differed on line endings alone (CRLF on
  disk, LF in the repo). The blobs and comments matched, so this is a
  normalisation and not a key mismatch - hence the CR-stripped second
  comparison in step 3.
- atuin binary path: the units default to `~/.atuin/bin/atuin`; on a
  package-managed host (`/usr/bin/atuin`) `bc_setup_atuin_daemon` writes
  a per-host `ExecStart` drop-in instead of failing 203/EXEC.

## After EVERY machine is migrated (do once, at the end)

- Delete the root `bashrc_core` compatibility stub - it only exists to
  catch an un-migrated box.
- Decommission the old `~/Documents/bash-config` checkout and its
  `secrets` submodule (runbook step 9).
- Delete the local working docs: `PR-draft.md`,
  `CHEZMOI-MIGRATION-REPORT.md`, and this playbook.
