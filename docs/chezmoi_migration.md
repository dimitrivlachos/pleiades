# Chezmoi migration plan

Getting from the current install.sh + secrets-submodule setup to a
chezmoi-managed repo, as one big PR from `main`. Level 1 is this PR;
Levels 2 and 3 are noted at the end so the path up is on record.

## Context

The setup today is a custom `install.sh`, a private `secrets` git
submodule, and `BASH_SPECIALISATION` file-switching. Three things hurt:

- **Submodule bootstrap ordering.** The `secrets` submodule clones over
  the `github.com-d` ssh alias, but that alias lives in `ssh_config`,
  which lives in the submodule. Chicken and egg on a fresh machine.
- **A leaked key.** `secrets/bash_secrets.sh` holds a live
  `OPENAI_API_KEY` committed in the submodule history.
- **`install.sh` reimplements chezmoi.** Managed-block editing,
  symlinking, per-machine switching, unit installation - all of it is
  what chezmoi does natively, and adding a new dotfile today is manual
  effort each time.

The ssh-rework branch also parked its `ssh_config` changes "for chezmoi";
they land here.

Goal: `chezmoi init --apply <repo>` takes a fresh machine from clone to
working, secrets decrypt locally from age-encrypted files in the same
repo, and the private submodule is gone.

## Decisions (locked)

1. **Source layout:** `home/` subdirectory as the chezmoi source root
   via `.chezmoiroot`. Repo meta (README, docs, licence) stays at the
   top level.
2. **Module deploy:** chezmoi copy + apply, not live symlinks. Every
   change is previewable with `chezmoi diff` before `chezmoi apply`.
3. **Specialisation:** collapse the three `bashrc_<name>` files into
   chezmoi templates branched on a `specialisation` data value.
4. **Secrets:** age encryption, one keypair, private identity copied to
   `~/.config/chezmoi/key.txt` per machine out-of-band. Rotate the
   leaked `OPENAI_API_KEY` as part of the move.

## Target structure

```
bash-config/                 (git repo root)
├─ README.md  docs/  LICENSE
├─ .chezmoiroot              -> "home"
└─ home/                     (chezmoi source root)
   ├─ .chezmoi.toml.tmpl     prompts specialisation at init, wires age
   ├─ .chezmoidata.toml      static data (specialisation -> host lists)
   ├─ .chezmoiexternal.toml  bash-preexec + tmux plugins (was submodules)
   ├─ .chezmoiignore         hide anything not meant for $HOME
   ├─ .chezmoitemplates/     specialisation-*, fastfetch-*, atuin-* partials
   ├─ dot_bashrc.tmpl        managed block: BASH_SPECIALISATION + source
   ├─ dot_config/
   │  ├─ bash-config/        the bash_* modules land here (BASH_CONFIG_DIR)
   │  │  ├─ bashrc_core
   │  │  ├─ bash_tools  bash_ssh  bash_history  ...
   │  │  ├─ specialisation.sh.tmpl   the collapsed specialisations
   │  │  ├─ gitconfig_base           base git aliases/core/colours
   │  │  └─ encrypted_private_bash_secrets.sh   (age)
   │  ├─ fastfetch/config.jsonc.tmpl per machine + arch (its XDG home)
   │  ├─ atuin/config.toml.tmpl      homelab or diamond (its XDG home)
   │  ├─ tmux/tmux.conf
   │  └─ systemd/user/*.service *.timer
   ├─ dot_gitconfig.tmpl     base + specialisation include + identity
   ├─ dot_aider.conf.yml  dot_aider.model.metadata.json
   ├─ private_dot_ssh/
   │  ├─ encrypted_private_config          (was secrets/ssh_config)
   │  ├─ encrypted_private_id_ed25519_sk_* (SK handles)
   │  └─ executable_smart-proxy            (was scripts/ssh-smart-proxy.sh)
   └─ encrypted_private_dot_config/git/user_public, user_private
```

## Mapping (current -> chezmoi source)

| Today | Becomes |
|---|---|
| `install.sh` managed block in `~/.bashrc` | `dot_bashrc.tmpl` renders the block; `BASH_SPECIALISATION` from data |
| `bashrc_core` + `bash_*` modules (sourced from checkout) | copied to `~/.config/bash-config/`; `BASH_CONFIG_DIR` points there |
| `specialisations/bashrc_{frostpaw,diamond,asteria}` | one `specialisation.sh.tmpl`, `{{ if eq .specialisation }}` blocks |
| `configs/gitconfig_*` + `secrets/gitconfig_user_*` | `dot_gitconfig.tmpl` + two encrypted identity includes |
| `configs/fastfetch_*.jsonc`, `configs/atuin/*` | promoted to their XDG homes as `dot_config/fastfetch/config.jsonc.tmpl` and `dot_config/atuin/config.toml.tmpl`, selected per machine at apply time via `.chezmoitemplates` partials |
| `configs/tmux/` + 3 plugin submodules | `dot_config/tmux/`; plugins via `.chezmoiexternal.toml` |
| `configs/systemd/user/*` | `dot_config/systemd/user/*` + a `run_onchange_` enabler |
| `secrets/bash_secrets.sh` | `encrypted_private_bash_secrets.sh` (key rotated) |
| `secrets/ssh_config` | `private_dot_ssh/encrypted_private_config` (deferred ssh-rework edits land here) |
| `secrets/sk_ssh_handles/id_ed25519_sk_*` | encrypted files in `private_dot_ssh/` |
| `secrets/certs/skypaw-ca.crt` | plaintext file + manual/`run_once` trust-store install |
| `scripts/ssh-smart-proxy.sh` | `private_dot_ssh/executable_smart-proxy` |
| `.gitmodules`, `secrets` submodule, `install.sh`/`uninstall.sh` | removed |

## Age and secrets

- Generate one age keypair. Public recipient goes in
  `.chezmoi.toml.tmpl`; private `key.txt` is copied to
  `~/.config/chezmoi/key.txt` on each machine and never committed.
- **Encrypt** (identity-linking or truly secret): `bash_secrets.sh`,
  `ssh_config`, `gitconfig_user_public`, `gitconfig_user_private`, and
  the `id_ed25519_sk_*` private handles.
- **Plaintext is fine** (already public today or not sensitive): the
  `*.pub` keys, `certs/*.crt`, and all the generic tooling in the bash
  modules and specialisations. The repo stays public, so only ciphertext
  and generic tooling are visible; the personal identity (author name and
  personal emails) stays inside encrypted files and is never exposed.
- **Rotate** `OPENAI_API_KEY` (a personal LLM endpoint). Rotate it at the
  provider after the migration; the encrypted
  `bash_secrets.sh` ships with a placeholder value and a ROTATE-ME note
  until then, so the compromised key is never re-committed. Drop the
  `id_ecdsa_sk_*` set, which nothing references.

## Behaviour changes to handle

- **Self-update.** `bash_config_update` / `bash_update` git-pull the
  checkout today. Under chezmoi the deployed modules are copies, so this
  becomes `chezmoi update` (pull source + apply). Drop the
  `.last_update_check` self-mutation.
- **Unit enablement.** `bc_setup_ssh_agent_service` and
  `bc_setup_atuin_daemon` install-and-enable units. chezmoi deploys the
  unit files; a small `run_onchange_` script does the
  `systemctl --user enable --now` and linger, gated by specialisation.
- **`migrate-ssh-agent.sh`** was a one-shot old->new agent move; it
  retires after this migration.

## Bootstrap flow (new machine)

```
# 1. install chezmoi (pacman -S chezmoi, or the upstream one-liner)
# 2. place the age key
install -Dm600 key.txt ~/.config/chezmoi/key.txt
# 3. clone, prompt for specialisation, decrypt, apply
chezmoi init --apply github.com/dimitrivlachos/bash-config
```

No `github.com-d` alias needed first: the repo is one public repo with
encrypted blobs, so the ordering problem is gone.

## Work phases (commits within the PR)

1. **Scaffold** `.chezmoiroot`, `home/`, config template, data,
   `.chezmoiignore`, `.chezmoiexternal.toml`. Nothing deployed yet.
2. **Migrate static configs**: bashrc block, modules to
   `~/.config/bash-config/`, gitconfig, fastfetch, tmux, aider, atuin,
   systemd units + enabler.
3. **Collapse specialisations** into `specialisation.sh.tmpl` and the
   templated gitconfig/fastfetch/atuin selection.
4. **Age + secrets**: generate keypair, encrypt the secret set, wire the
   config, rotate the API key, dissolve the submodule and `.gitmodules`.
5. **Retire** `install.sh`/`uninstall.sh`; rewrite README bootstrap.
6. **Verify** end-to-end (below).

## Verification

- `chezmoi doctor` clean; `chezmoi diff` reviewed before any apply.
- Dry run on this machine (frostpaw): `chezmoi apply --dry-run --verbose`
  and inspect. Then a real apply, confirming: the `~/.bashrc` managed
  block, modules under `~/.config/bash-config/`, `~/.ssh/config` decrypts
  with the right per-machine content, SK handles present, systemd units
  active, gitconfig identity include resolves.
- New login shell sanity: specialisation loads, prompt, atuin, ssh agent
  reachable, `git config user.email` correct.
- Confirm a `git grep` of the public repo shows no plaintext secrets and
  no work-identity linkage.

## Not in this PR (roadmap)

- **Level 2 - absorb more dotfiles.** `chezmoi add` for nvim, terminal
  emulator, starship, and the rest, incrementally, no big-bang day.
- **Level 3 - provisioning.** `run_once_`/`run_onchange_` scripts for
  package bootstrap (paru/pacman, per-distro branch) and unit
  enablement, so bare metal to working is one command.
- **Windows.** `install_windows.ps1` stays unmanaged for now; chezmoi
  can template it in later if worth it.
