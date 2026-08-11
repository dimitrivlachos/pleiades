# Pleiades rollout - remaining machines

- [ ] **asteria**

## Per box, in short (see playbook for the full checks)

1. Pre-flight survey (host, arch, spec, key present?, old symlinks?).
2. `chezmoi init dimitrivlachos/pleiades` (preset the spec with
   `--promptChoice 'Machine specialisation=<spec>'` if non-interactive).
3. Drop the age key at `~/.config/chezmoi/key.txt` (out-of-band, user).
4. Clear old `install.sh` symlinks - `~/.config/tmux` is the trap.
5. `chezmoi diff` + SK-handle byte-identity check, then
   `chezmoi apply`.
6. Reload, run the specialisation's `bc_setup_*` steps, `bc_doctor`.

## Finalize (once EVERY machine is migrated)

- [ ] Delete the root `bashrc_core` compatibility stub.
- [ ] Decommission the old `~/Documents/bash-config` checkout + `secrets`
  submodule (`docs/migrating_to_chezmoi.md` step 9).
- [ ] Delete the working docs: `migration.md` and this file.
