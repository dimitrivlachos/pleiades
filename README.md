# 🌀 bash-config

Modular, secure, and portable Bash configuration, managed with
[chezmoi](https://www.chezmoi.io/) and specialised per machine.

This repo is designed to be:

- 🧩 **Modular** – clean separation of shared and machine-specific logic
- 🛡️ **Secure** – secrets are age-encrypted in the source and decrypted
  only on the target machine, so the repo can stay public
- 🧼 **Maintainable** – one `chezmoi apply` deploys everything, and
  `chezmoi diff` shows the change first
- 🌍 **Portable** – one source, many machines, via a per-machine
  specialisation value

---

## 📁 Structure

chezmoi treats `home/` as its source root (via `.chezmoiroot`), and the
`dot_` / `private_` / `encrypted_` prefixes map to real dotfiles on
apply.

```
bash-config/
├── .chezmoiroot                    # points chezmoi at home/
├── home/
│   ├── .chezmoi.toml.tmpl          # prompts specialisation, sets age
│   ├── .chezmoiexternal.toml       # bash-preexec + tmux plugins (fetched)
│   ├── .chezmoitemplates/          # specialisation-*, fastfetch-*, atuin-* partials
│   ├── modify_dot_bashrc.tmpl      # refreshes the managed ~/.bashrc block
│   ├── dot_gitconfig.tmpl          # ~/.gitconfig, identity by specialisation
│   ├── dot_config/
│   │   ├── bash-config/            # the modules -> ~/.config/bash-config/
│   │   │   ├── bashrc_core         # orchestrator sourced by ~/.bashrc
│   │   │   ├── bash_aliases, bash_ssh, bash_tools, ...
│   │   │   ├── specialisation.sh.tmpl  # renders this machine's partial
│   │   │   ├── gitconfig_base      # shared git aliases/core/colours
│   │   │   └── encrypted_*.age     # secrets (bash_secrets, git identities)
│   │   ├── fastfetch/config.jsonc.tmpl  # -> ~/.config/fastfetch/ (per machine+arch)
│   │   ├── atuin/config.toml.tmpl       # -> ~/.config/atuin/ (homelab or diamond)
│   │   ├── tmux/tmux.conf          # -> ~/.config/tmux/
│   │   └── systemd/user/           # atuin-daemon + ssh-agent units
│   └── private_dot_ssh/            # ssh config + SK handles (encrypted)
└── docs/
    ├── chezmoi_migration.md        # the migration plan
    └── migrating_to_chezmoi.md     # per-machine cutover runbook
```

---

## 🚀 Installation (new machine)

You need the age identity (`key.txt`, kept in Vaultwarden) to decrypt
secrets. chezmoi has age built in, so no separate `age` binary is
required.

### 1. Install chezmoi and clone the source

```bash
sh -c "$(curl -fsLS get.chezmoi.io)" -- init dimitrivlachos/bash-config
```

This installs chezmoi, clones the source, prompts for the machine
specialisation, and writes `~/.config/chezmoi/chezmoi.toml`.

### 2. Drop the age key in place

```bash
install -m 600 -D /path/to/key.txt ~/.config/chezmoi/key.txt
```

### 3. Preview and apply

```bash
chezmoi diff
chezmoi apply
exec bash -l
```

`apply` deploys the modules, decrypts the secrets, and adds this block
to `~/.bashrc`:

```bash
# >>> bash-config initialize >>>
export BASH_SPECIALISATION="frostpaw"
source "$HOME/.config/bash-config/bashrc_core"
# <<< bash-config initialize <<<
```

A few things chezmoi deploys but does not activate (systemd units, the
homelab CA) have one-shot enable steps; see the runbook below.

### Migrating an existing machine

If the machine is currently on the old `install.sh` layout (symlinks
plus a `secrets` submodule), follow the cutover runbook instead:
[`docs/migrating_to_chezmoi.md`](docs/migrating_to_chezmoi.md). It
covers clearing the old symlinks, enabling the systemd units, and the
SSH key rename.

---

## 🔄 Updating

```bash
chezmoi update          # pull the source, then apply
```

or, equivalently, the wrappers that also show you what is coming:

```bash
bc_update_config        # show pending source changes
bc_update_config update # apply them (calls chezmoi update)
```

A daily login check nudges you when the source is behind upstream.

---

## 🧠 Specialisations

The specialisation is chosen at `chezmoi init` and stored in
`~/.config/chezmoi/chezmoi.toml`. It drives both the templates and the
`BASH_SPECIALISATION` export.

| Name | Description |
| ---- | ----------- |
| frostpaw | Home setup (Arch Linux, modern CLI tools, yay/paru updates) |
| diamond | Work setup (CUDA/CMake modules, pixi tools, SSH agent, hostname mapping) |
| asteria | Headless personal server |

To change a machine's specialisation, re-run `chezmoi init` or edit the
value in `~/.config/chezmoi/chezmoi.toml`, then `chezmoi apply`.

---

## 🔑 Secrets 🔐

Secrets are age-encrypted in the source (the `encrypted_*.age` files)
and decrypted on apply into `~/.config/bash-config/`:

- `bash_secrets.sh` – usernames, key paths, tokens
- `gitconfig_user_public` / `gitconfig_user_private` – git identities
- `~/.ssh/config` and the SK key handles

The single age identity lives at `~/.config/chezmoi/key.txt` on each
machine (copied out-of-band from Vaultwarden, never committed). Because
only ciphertext and generic tooling are in the repo, it can stay public.

To edit a secret:

```bash
chezmoi edit ~/.config/bash-config/bash_secrets.sh   # decrypts, re-encrypts on save
chezmoi apply
```

---

## 🔧 Git Configuration

`~/.gitconfig` is a chezmoi template (`dot_gitconfig.tmpl`). It includes
the shared base config and picks an identity:

- **diamond**: always the public (work) identity.
- **personal machines**: the identity is chosen by the account the
  repo's remote points at - `git@github.com-d:...` uses the public
  account, `git@github.com-s:...` the private one.

The base config (`gitconfig_base`) carries 40+ aliases and
sensible core/pull/push defaults. There is no `git-setup` step any more;
`chezmoi apply` deploys `~/.gitconfig`. Validate with
`bc_check_git_config`.

### Using Git aliases

```bash
git aliases        # list all aliases
git s              # short status with branch info
git cm "message"   # commit with message
git l              # compact log with graph
git undo           # undo last commit (keeps changes)
```

---

## 🐍 Pixi Package Manager (Diamond)

[Pixi](https://prefix.dev/docs/pixi) manages user-space CLI tools on
Diamond without root, keeping everything on the science volume.

The Diamond specialisation sets pixi up when `DIAMOND_USERNAME` is
defined in `bash_secrets.sh`:

```bash
export PIXI_HOME="/dls/science/users/$DIAMOND_USERNAME/.pixi"
export PIXI_CACHE_DIR="$PIXI_HOME/cache"
# $PIXI_HOME/bin is added to PATH automatically if the directory exists
```

Install tools with `pixi global install ...`. Modern CLI aliases
(`eza`, `bat`, `ripgrep`, `fd`) apply interactively only, so scripts are
unaffected. Run `diamond-help` (or `dh`) for the full Diamond reference.

---

## 📜 Atuin History

[Atuin](https://github.com/atuinsh/atuin) is the primary history
backend, providing cross-machine sync, per-command metadata, and the
Ctrl+R search UI.

Atuin relies on [bash-preexec](https://github.com/rcaloras/bash-preexec)
to hook bash's `preexec`/`precmd` lifecycle. **Without it, atuin records
nothing.** It is fetched as a chezmoi external into
`~/.config/bash-config/bash-preexec/`; verify with:

```bash
bc_check_bash_preexec   # installed and active?
bc_verify_atuin         # sync server connectivity (frostpaw)
```

Recording flow:

```
bash runs a command
  → bash-preexec fires preexec → __atuin_preexec → atuin history start
  → command executes
  → bash-preexec fires precmd  → __atuin_precmd  → atuin history end
```

The bash `HISTFILE` is still maintained as a passive text backup via
`history -a`, so it survives if atuin is ever unavailable.

---

## 💡 Prompt Toggles

| Command | Description |
| ------- | ----------- |
| `tgit` | Toggle Git branch display |
| `tdir` | Toggle long `\W` / short `\w` directory display |
| `tem` | Toggle emoji in prompt |
| `ph` | Show all prompt helpers |
| `rp` | Reset prompt to default |

Available on all systems.
