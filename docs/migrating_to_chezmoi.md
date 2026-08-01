# Migrating an existing machine to chezmoi

The one time your dotfiles fight back. This is the per-machine runbook
for moving a box off the old `install.sh` world (symlinks into a repo
checkout plus a `secrets` submodule) and onto the chezmoi-managed
version. It is a deliberate manual cutover, run once per machine, not
something a `git pull` does for you.

Do it on your own machines in whatever order suits you. Nothing here
touches a machine until you run `chezmoi apply`, and `chezmoi diff`
lets you read the whole change first.

## What actually changes

Old world:

- The repo is a live git checkout (e.g. `~/Documents/bash-config`).
- `~/.bashrc` sources `~/.bashrc_core`, a symlink into that checkout.
- `~/.ssh/config`, `~/.config/tmux`, `~/.aider.conf.yml` are symlinks
  into the checkout; secrets live in a submodule.
- `install.sh` and the `bc_setup_*` helpers do the deployment.

New world:

- chezmoi owns the source (`~/.local/share/chezmoi`) and deploys real
  files: the modules land in `~/.config/bash-config/`, and the managed
  block in `~/.bashrc` sources `~/.config/bash-config/bashrc_core`.
- Secrets are age-encrypted in the source and decrypted on apply, using
  the identity at `~/.config/chezmoi/key.txt`.
- Updates are `chezmoi update` (pull the source, then apply).

## One warning before you start

On a machine you have **not** migrated yet, do not run the old
`bc_update_config update`. It still does `git merge --ff-only` on the
checkout, which pulls this migration in and deletes the root
`bashrc_core` that `~/.bashrc_core` points at. The compatibility stub
softens that (you get a message, not a broken prompt), but the fix is
still to migrate the machine. The daily update check only warns; it
never merges on its own, so simply logging in is safe.

## Pre-flight (once, not per machine)

- Have the age identity to hand: `key.txt`, backed up in Vaultwarden.
  It is the only thing that decrypts the secrets.
- chezmoi has age built in, so you do not need a separate `age` binary
  on each machine. Install the `age` CLI only if you want it for other
  reasons.

## Per-machine steps

### 1. Install chezmoi and clone the source

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init dimitrivlachos/pleiades
```

This installs chezmoi, clones the source to `~/.local/share/chezmoi`,
prompts for the machine specialisation (frostpaw / diamond / asteria),
and writes `~/.config/chezmoi/chezmoi.toml`. It does not apply anything
yet, and it does not need the age key at this stage.

### 2. Drop the age key in place

```bash
install -m 600 -D /path/to/key.txt ~/.config/chezmoi/key.txt
```

`chezmoi apply` cannot decrypt the secrets without this.

### 3. Clear the old symlinks

chezmoi will not clean these up, and one of them is actively dangerous:
if `~/.config/tmux` is still a symlink into the old checkout, chezmoi
writes `tmux.conf` and the plugin externals *through* it, into the old
repo instead of your real config dir. Remove the old symlinks first:

```bash
rm -f ~/.bashrc_core
[ -L ~/.config/tmux ]      && rm ~/.config/tmux
[ -L ~/.aider.conf.yml ]   && rm ~/.aider.conf.yml
[ -L ~/.ssh/config ]       && rm ~/.ssh/config
# atuin/fastfetch now live at their XDG homes; drop any old symlink there:
[ -L ~/.config/atuin/config.toml ] && rm ~/.config/atuin/config.toml
# old SK key-handle symlinks, if any:
find ~/.ssh -maxdepth 1 -type l -name 'id_ed25519_sk_*' -delete
```

### 4. Preview, then apply

```bash
chezmoi diff        # read the whole change first
chezmoi apply       # deploy + decrypt; needs network for the externals
```

Apply rewrites the managed block in `~/.bashrc` to source
`~/.config/bash-config/bashrc_core`, so the old `~/.bashrc_core` symlink
is no longer referenced (you removed it in step 3 anyway).

### 5. Reload the shell

```bash
exec bash -l
```

### 6. Enable the systemd units (chezmoi deploys them, does not enable)

chezmoi writes the unit files to `~/.config/systemd/user/`, but enabling
them is a separate step. Run the ones your specialisation uses:

```bash
# frostpaw and asteria (any non-diamond box with systemd):
bc_setup_ssh_agent_service

# frostpaw only:
bc_setup_atuin_daemon     # enables the daemon + health-check timer + linger
bc_setup_certs            # sudo: installs the homelab CA into the trust store
```

Each of these now just reloads and enables what chezmoi laid down, and
they are idempotent, so re-running is harmless.

### 7. Standardise the SSH key names

The migration drops the legacy `id_ed25519_{d,s}` key name in favour of
the explicit `id_ed25519_github_{d,s}`. Same key, no change on GitHub;
until you rename, `-d`/`-s` GitHub auth falls back to the SK key (a
touch per push) or fails if the YubiKey is absent.

```bash
for a in d s; do
  [ -f ~/.ssh/id_ed25519_$a ]     && mv ~/.ssh/id_ed25519_$a     ~/.ssh/id_ed25519_github_$a
  [ -f ~/.ssh/id_ed25519_$a.pub ] && mv ~/.ssh/id_ed25519_$a.pub ~/.ssh/id_ed25519_github_$a.pub
done
```

### 8. Verify

```bash
bc_validate_config                       # config, git, ssh, certs checks
chezmoi managed | head                   # what chezmoi now owns
bc_check_bash_preexec                    # atuin's hook dependency (external)
ssh -G github.com-d | grep -i identityfile   # expect id_ed25519_github_d
```

### 9. Decommission the old checkout

Once nothing references it, the old runtime checkout (the one
`~/.bashrc_core` used to point at) and its `secrets` submodule can go.
If you also use that clone to work *on* the repo, keep it as a plain dev
clone; only the runtime role has moved to chezmoi. You can also tidy any
`~/.bashrc.backup.*` / `~/.gitconfig.backup.*` the old installer left.

## After every machine is migrated

Delete the root `bashrc_core` compatibility stub. It only exists to
catch a machine that pulled the migration before running this runbook,
and once none are left it is just litter.
