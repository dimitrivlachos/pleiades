# Bash Config Enhancement Ideas

Ideas for future improvements to the bash configuration system.

## Navigation & Directory Management

- [ ] **Smart Directory Bookmarks** - Quick navigation to frequently used directories
  - `bm <name>` to save current directory
  - `go <name>` to jump to saved directory
  - `bml` to list all bookmarks
  
- [ ] **Smart `cd` with History** - Track directory changes and navigate back through history
  - `cdb` to go back through previous directories
  - Persistent directory stack across sessions
  
- [ ] **Project Context Switcher** - Automatically load project-specific environments
  - Detect `.project.env` files in current/parent directories
  - Auto-activate conda/venv environments
  - Set project-specific environment variables

## Productivity Tools

- [ ] **Clipboard Integration** - Easy copy/paste between terminal and system clipboard
  - `cpwd` to copy current directory path
  - `clc` to copy last command
  - Cross-platform support (xclip/pbcopy)

- [ ] **Quick Notes System** - Terminal-based note-taking
  - `note <text>` to add timestamped notes
  - `note` to view all notes
  - `ns <query>` to search notes

- [ ] **Command Timing** - Track execution time of commands
  - `t <command>` to time a command
  - Show duration and exit status

## Environment Management

- [ ] **Environment Snapshots** - Save and restore complete working environments
  - `bc_env_snapshot [name]` to save current state
  - `bc_env_list` to list available snapshots
  - Capture PWD, conda env, virtualenv, custom variables

- [x] **Session Recording & Logging** - superseded by atuin. The daemon,
  its health-check timer and cross-machine sync (`bash_history`) already
  give a searchable, per-host audit trail, so a bespoke session log
  would be a second worse copy of it.

## System Monitoring

- [ ] **System Health Dashboard** - Quick overview of system resources
  - `health` command to show CPU, memory, disk, network
  - Color-coded output for at-a-glance status
  - Lightweight and fast

## Code Quality

- [x] **Automated validation** - landed as CI rather than a git hook:
  `.github/workflows/verify.yml` runs `bash -n` over every module,
  renders all three specialisations, validates the fastfetch and
  opencode configs, and runs a four-step secret leak guard.
  - [ ] Shellcheck integration
  - [ ] Auto-formatting with shfmt
  - [ ] Mirror the CI checks into a local pre-commit hook so a leak is
    caught before it reaches GitHub, not after

- [ ] **Performance Profiling** - Identify slow parts of bash config
  - Measure load time of each component
  - `bc_profile` command to analyze startup time

## Documentation

- [x] **Interactive Help System** - `bc_help` lists the commands and
  takes a topic argument; `bc_ssh_help`, `bc_project_help`,
  `update_help` and `hhelp` cover their own modules.
  - [ ] Auto-generate the text from function comments instead of
    maintaining it by hand

## Advanced Features

- [ ] **Auto-completion Enhancements** - Better tab completion
  - Custom completions for all `bc_*` functions
  - Context-aware suggestions
  - Fuzzy matching support

