# shellcheck shell=bash
# Shared helpers for claude-box / opencode-box / pi-box. Sourced, not executed.
#
# Argument convention:
#
#   <tool>-box [PATH...] [-- CLI_ARG...]
#
# $PWD is always mounted at /work and is the working directory. Paths listed
# before `--` are extra host paths to expose; each is mounted read-write at
# /mnt/<basename>. Everything after `--` is passed to the CLI verbatim.
#
# Without a `--`, every argument goes to the CLI, so `claude-box --resume xyz`
# keeps working.

# Podman flags common to all three wrappers. $PWD is mounted here so it is the
# one mount every tool gets.
ABOX_COMMON=(
  --rm -it
  --userns=keep-id:uid=1000,gid=1000
  --security-opt no-new-privileges
  --cap-drop=ALL
  -v "$PWD:/work:z"
  -w /work
  -e TERM
)

# Populated by abox_parse.
ABOX_MOUNTS=()
ABOX_ARGS=()

abox_parse() {
  local me="${0##*/}"
  local paths=() seen_sep=0 arg

  for arg in "$@"; do
    if [ "$seen_sep" -eq 0 ] && [ "$arg" = "--" ]; then
      seen_sep=1
    elif [ "$seen_sep" -eq 1 ]; then
      ABOX_ARGS+=("$arg")
    else
      paths+=("$arg")
    fi
  done

  # No separator: treat everything as CLI arguments, mount nothing extra.
  if [ "$seen_sep" -eq 0 ]; then
    ABOX_ARGS=("${paths[@]}")
    return 0
  fi

  local pwd_real name dest real n
  local -A used=()
  pwd_real=$(readlink -f -- "$PWD")

  for arg in "${paths[@]}"; do
    real=$(readlink -f -- "$arg" || true)
    if [ -z "$real" ] || [ ! -e "$real" ]; then
      echo "$me: no such path: $arg" >&2
      return 1
    fi
    # $PWD is already at /work; don't expose it twice under a second path.
    if [ "$real" = "$pwd_real" ]; then
      echo "$me: $arg is the working directory, already mounted at /work" >&2
      continue
    fi
    name=$(basename -- "$real")
    case "$name" in '' | '/' | '.' | '..') name=root ;; esac
    dest=$name
    n=2
    while [ -n "${used[$dest]:-}" ]; do
      dest="$name-$n"
      n=$((n + 1))
    done
    used[$dest]=$real
    ABOX_MOUNTS+=(-v "$real:/mnt/$dest:z")
    echo "$me: $real -> /mnt/$dest" >&2
  done
}
