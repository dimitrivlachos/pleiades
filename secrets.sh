#!/bin/bash
# ==============================================================================
# Secrets scratch pad - bulk decrypt/edit/re-encrypt of the age-encrypted source
# ==============================================================================
# Decrypts every tracked encrypted_*.age file into .secrets/, laid out like the
# deployed $HOME, and re-encrypts the changed ones.
#
# age is non-deterministic, so only files whose plaintext hash changed since
# unseal are re-encrypted. The ciphertext hash is tracked too: a source file
# that changed since unseal is stale, and sealing over it needs --force.
#
# Operates on the clone it lives in, not `chezmoi source-path`; those are
# separate trees on some machines, and encrypt/decrypt need only the config.
#
# `clean` is a plain rm, not shred. Overwriting in place is best-effort on a
# journaling filesystem, so shred would imply a guarantee it cannot make.
#
# Usage:
#   ./secrets.sh unseal [filter...]   decrypt into .secrets/ (--force to clobber)
#   ./secrets.sh status               per-file state against the manifest
#   ./secrets.sh seal [filter...]     re-encrypt changed files (--force if stale)
#   ./secrets.sh clean                remove .secrets/
#   ./secrets.sh help
#
# A filter is a substring matched against the source path: `unseal ssh`,
# `unseal claude`, `unseal bash-config`.
#
# .secrets/ is not /secrets/, the dissolved submodule's leftover plaintext
# checkout that .gitignore also excludes.
# ==============================================================================

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRATCH="$ROOT/.secrets"
MANIFEST="$SCRATCH/.manifest"
IDENTITY="${CHEZMOI_AGE_IDENTITY:-$HOME/.config/chezmoi/key.txt}"

# Everything this script writes is plaintext secrets or derived from them.
umask 077

_log_info()    { printf '\033[0;36m  %s\033[0m\n' "$1"; }
_log_warn()    { printf '\033[0;33m  ! %s\033[0m\n' "$1" >&2; }
_log_error()   { printf '\033[0;31m  x %s\033[0m\n' "$1" >&2; }
_log_success() { printf '\033[0;32m  %s\033[0m\n' "$1"; }

usage() {
  sed -n '/^# Usage:/,/^# ===/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'
}

# ==============================================================================
# Preflight
# ==============================================================================

preflight() {
  if ! command -v chezmoi >/dev/null 2>&1; then
    _log_error "chezmoi is not on PATH"
    exit 1
  fi
  # age reports a missing identity as "no identity matched any of the
  # recipients", which does not name the cause.
  if [[ ! -r "$IDENTITY" ]]; then
    _log_error "age identity not readable at $IDENTITY"
    _log_error "copy it out-of-band (Vaultwarden) before unsealing"
    exit 1
  fi
}

# Populates SRCS with tracked ciphertext only; untracked files in the working
# tree are never swept into the scratch pad.
collect_sources() {
  local filters=("$@") src keep f
  SRCS=()
  while IFS= read -r src; do
    if [[ ${#filters[@]} -eq 0 ]]; then
      SRCS+=("$src")
      continue
    fi
    keep=0
    for f in "${filters[@]}"; do
      [[ "$src" == *"$f"* ]] && keep=1 && break
    done
    [[ $keep -eq 1 ]] && SRCS+=("$src")
  done < <(git -C "$ROOT" ls-files -- 'home/*.age' | sort)

  if [[ ${#SRCS[@]} -eq 0 ]]; then
    _log_error "no tracked .age files matched"
    exit 1
  fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# ==============================================================================
# Path mapping
# ==============================================================================

# Populates RELS with the scratch path for each entry in SRCS. chezmoi owns the
# encrypted_/private_/dot_ attribute grammar, so the mapping is delegated to it
# rather than reimplemented: one batch call, one output line per input, in order.
#
# chezmoi reports the rendered target and so strips .tmpl. The scratch pad keeps
# it, marking the file as template source rather than a rendered target.
map_targets() {
  local -a targets
  mapfile -t targets < <(cd "$ROOT" && chezmoi --source "$ROOT/home" target-path "${SRCS[@]}")

  if [[ ${#targets[@]} -ne ${#SRCS[@]} ]]; then
    _log_error "chezmoi target-path returned ${#targets[@]} paths for ${#SRCS[@]} files"
    exit 1
  fi

  RELS=()
  local i rel
  for i in "${!SRCS[@]}"; do
    rel="${targets[$i]#"$HOME"/}"
    [[ "$(basename -- "${SRCS[$i]}")" == *.tmpl.age ]] && rel="$rel.tmpl"
    RELS+=("$rel")
  done
}

# ==============================================================================
# Status
# ==============================================================================

# Classifies every manifest row into two globals keyed by relative path.
#
# STATE is what happened to the plaintext:
#   modified  edited, seal will re-encrypt it
#   unchanged untouched, seal will skip it
#   missing   deleted from the scratch pad
#
# STALE is whether the .age changed underneath since unseal. It is separate from
# STATE because the two are orthogonal - a pull can land on a file that also has
# a pending edit - and folding drift into STATE would mask that edit from clean.
read_status() {
  declare -gA STATE=() STALE=() SRC_OF=()
  N_MODIFIED=0 N_UNCHANGED=0 N_MISSING=0 N_STALE=0

  [[ -f "$MANIFEST" ]] || return 0

  local psha csha src rel plain
  while IFS=$'\t' read -r psha csha src rel; do
    [[ -n "$rel" ]] || continue
    plain="$SCRATCH/$rel"
    SRC_OF["$rel"]="$src"

    if [[ ! -f "$ROOT/$src" ]] || [[ "$(sha "$ROOT/$src")" != "$csha" ]]; then
      STALE["$rel"]=1
      ((N_STALE++)) || true
    else
      STALE["$rel"]=0
    fi

    if [[ ! -f "$plain" ]]; then
      STATE["$rel"]=missing
      ((N_MISSING++)) || true
    elif [[ "$(sha "$plain")" != "$psha" ]]; then
      STATE["$rel"]=modified
      ((N_MODIFIED++)) || true
    else
      STATE["$rel"]=unchanged
      ((N_UNCHANGED++)) || true
    fi
  done < "$MANIFEST"
}

# Populates UNTRACKED with scratch files that have no manifest row. seal cannot
# place these; only `chezmoi add --encrypt` can assign the source attributes.
list_untracked() {
  local f rel
  UNTRACKED=()
  [[ -d "$SCRATCH" ]] || return 0
  while IFS= read -r f; do
    rel="${f#"$SCRATCH"/}"
    [[ "$rel" == .manifest || "$rel" == .gitignore ]] && continue
    [[ -n "${STATE[$rel]+x}" ]] || UNTRACKED+=("$rel")
  done < <(find "$SCRATCH" -type f | sort)
}

cmd_status() {
  if [[ ! -f "$MANIFEST" ]]; then
    _log_info "nothing unsealed (no $MANIFEST)"
    return 0
  fi

  read_status
  list_untracked

  local rel mark
  for rel in $(printf '%s\n' "${!STATE[@]}" | sort); do
    mark=""
    [[ "${STALE[$rel]}" == 1 ]] && mark="  (stale)"
    case "${STATE[$rel]}" in
      modified)  printf '\033[0;33m  modified   %s%s\033[0m\n' "$rel" "$mark" ;;
      missing)   printf '\033[0;31m  missing    %s%s\033[0m\n' "$rel" "$mark" ;;
      unchanged)
        if [[ -n "$mark" ]]; then
          printf '\033[0;31m  stale      %s\033[0m\n' "$rel"
        else
          printf '\033[0;90m  unchanged  %s\033[0m\n' "$rel"
        fi
        ;;
    esac
  done
  for rel in "${UNTRACKED[@]}"; do
    printf '\033[0;33m  untracked  %s\033[0m\n' "$rel"
  done

  echo
  _log_info "$N_MODIFIED modified, $N_UNCHANGED unchanged, $N_MISSING missing, $N_STALE stale, ${#UNTRACKED[@]} untracked"
  [[ $N_STALE -gt 0 ]] && _log_warn "stale: the ciphertext changed since unseal (pull?) - re-unseal, or seal --force to overwrite"
  return 0
}

# ==============================================================================
# Unseal
# ==============================================================================

cmd_unseal() {
  local force=0
  local -a filters=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *)       filters+=("$arg") ;;
    esac
  done

  preflight

  # Unsealing rewrites the scratch pad, so pending edits require --force.
  if [[ -f "$MANIFEST" && $force -eq 0 ]]; then
    read_status
    if [[ $N_MODIFIED -gt 0 ]]; then
      _log_error "$N_MODIFIED file(s) have unsealed edits - seal them, or clean first"
      exit 1
    fi
  fi

  collect_sources "${filters[@]}"
  map_targets

  rm -rf "$SCRATCH"
  mkdir -p "$SCRATCH"
  chmod 0700 "$SCRATCH"
  # Second line of defence: the scratch pad stays ignored independently of the
  # root .gitignore entry.
  printf '*\n' > "$SCRATCH/.gitignore"

  : > "$MANIFEST"
  local i src rel dest
  for i in "${!SRCS[@]}"; do
    src="${SRCS[$i]}"
    rel="${RELS[$i]}"
    dest="$SCRATCH/$rel"
    mkdir -p -- "$(dirname -- "$dest")"
    if ! chezmoi decrypt "$ROOT/$src" --output "$dest"; then
      _log_error "failed to decrypt $src"
      exit 1
    fi
    chmod 0600 "$dest"
    printf '%s\t%s\t%s\t%s\n' "$(sha "$dest")" "$(sha "$ROOT/$src")" "$src" "$rel" >> "$MANIFEST"
  done
  chmod 0600 "$MANIFEST"

  _log_success "unsealed ${#SRCS[@]} file(s) into ${SCRATCH/#$HOME/\~}"
  _log_info "edit freely, then: ./secrets.sh seal && ./secrets.sh clean"
}

# ==============================================================================
# Seal
# ==============================================================================

cmd_seal() {
  local force=0
  local -a filters=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      *)       filters+=("$arg") ;;
    esac
  done

  preflight

  if [[ ! -f "$MANIFEST" ]]; then
    _log_error "nothing unsealed (no $MANIFEST)"
    exit 1
  fi

  read_status
  list_untracked

  if [[ $N_STALE -gt 0 && $force -eq 0 ]]; then
    _log_error "$N_STALE file(s) are stale - their ciphertext changed since unseal"
    _log_error "sealing would revert that change; re-unseal, or pass --force"
    exit 1
  fi

  local rel src matched f sealed=0 skipped=0
  for rel in $(printf '%s\n' "${!STATE[@]}" | sort); do
    if [[ ${#filters[@]} -gt 0 ]]; then
      matched=0
      for f in "${filters[@]}"; do
        [[ "${SRC_OF[$rel]}" == *"$f"* ]] && matched=1 && break
      done
      [[ $matched -eq 1 ]] || continue
    fi

    case "${STATE[$rel]}" in
      # Deleting a source file is left to `chezmoi forget` and `git rm`.
      missing)
        _log_warn "missing from scratch, source left alone: $rel"
        continue
        ;;
      unchanged)
        ((skipped++)) || true
        continue
        ;;
    esac

    src="${SRC_OF[$rel]}"
    if ! chezmoi encrypt "$SCRATCH/$rel" --output "$ROOT/$src"; then
      _log_error "failed to encrypt $rel"
      exit 1
    fi
    chmod 0644 "$ROOT/$src"   # ciphertext is committed, not private
    _log_success "sealed $rel -> $src"
    ((sealed++)) || true
  done

  for rel in "${UNTRACKED[@]}"; do
    _log_warn "no source for $rel - add it with: chezmoi add --encrypt ~/${rel%.tmpl}"
  done

  # Re-baseline the hashes of what was just written, so a repeated seal is a
  # no-op rather than a second round of fresh ciphertext.
  if [[ $sealed -gt 0 ]]; then
    local psha csha msrc mrel tmp
    tmp="$(mktemp)"
    while IFS=$'\t' read -r psha csha msrc mrel; do
      [[ -n "$mrel" ]] || continue
      if [[ -f "$SCRATCH/$mrel" && -f "$ROOT/$msrc" ]]; then
        psha="$(sha "$SCRATCH/$mrel")"
        csha="$(sha "$ROOT/$msrc")"
      fi
      printf '%s\t%s\t%s\t%s\n' "$psha" "$csha" "$msrc" "$mrel"
    done < "$MANIFEST" > "$tmp"
    mv "$tmp" "$MANIFEST"
    chmod 0600 "$MANIFEST"
  fi

  echo
  _log_info "$sealed re-encrypted, $skipped unchanged"
  if [[ $sealed -gt 0 ]]; then
    _log_info "review with 'git diff --stat', then 'chezmoi apply' - seal does not deploy"
  fi
  _log_info "plaintext is still on disk - './secrets.sh clean' when done"
}

# ==============================================================================
# Clean
# ==============================================================================

cmd_clean() {
  if [[ ! -d "$SCRATCH" ]]; then
    _log_info "nothing to clean"
    return 0
  fi

  if [[ -f "$MANIFEST" ]]; then
    read_status
    if [[ $N_MODIFIED -gt 0 ]]; then
      _log_error "$N_MODIFIED file(s) have unsealed edits - seal them first, or rm -rf $SCRATCH"
      exit 1
    fi
  fi

  rm -rf "$SCRATCH"
  _log_success "removed ${SCRATCH/#$HOME/\~}"
}

# ==============================================================================
# Dispatch
# ==============================================================================

case "${1:-help}" in
  unseal) shift; cmd_unseal "$@" ;;
  status) shift; cmd_status ;;
  seal)   shift; cmd_seal "$@" ;;
  clean)  shift; cmd_clean ;;
  help|-h|--help) usage ;;
  *)
    _log_error "unknown command: $1"
    echo
    usage
    exit 1
    ;;
esac
