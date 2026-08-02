# Pleiades rollout - remaining machines

Follow `MIGRATION-PLAYBOOK.md` on each box. spark-f222 (frostpaw) is
done and merged (PR #2); the source of truth is GitHub
`dimitrivlachos/pleiades` `main`.

## Machines

- [ ] **Remaining frostpaw workstations** (every frostpaw box except
  spark-f222). Full stack: `bc_setup_ssh_agent_service`,
  `bc_setup_atuin_daemon`, `bc_setup_certs`, then `bc_doctor` green.
- [ ] **diamond** (work HPC). `bc_doctor` skips the atuin daemon and
  certs; no ssh-agent unit; pixi keys off `DIAMOND_USERNAME`. Expect no
  passwordless sudo and a locked-down `$HOME`.
- [ ] **asteria** (headless Pi). systemd -> `bc_setup_ssh_agent_service`;
  `atuin-homelab` config; no frostpaw daemon/certs. Age key goes in
  over SSH.

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
  submodule (runbook step 9).
- [ ] Delete the local working docs: `PR-draft.md`,
  `CHEZMOI-MIGRATION-REPORT.md`, `MIGRATION-PLAYBOOK.md`, and this file.
