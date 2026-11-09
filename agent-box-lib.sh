# shellcheck shell=bash
# Shared helpers for claude-box / opencode-box / pi-box. Sourced, not executed.
# Wrapper flags (--docker, --shell) are described at abox_setup below.
#
# Argument convention:
#
#   <tool>-box [PATH...] [-- CLI_ARG...]
#
# $PWD is mounted at /work and is the working directory -- except inside
# ~/Projects, where the whole Projects dir is mounted at its real host path
# and the box starts in $PWD's real path (see below). Paths listed before `--`
# are extra host paths to expose; each is mounted read-write at
# /mnt/<basename>. Everything after `--` is passed to the CLI verbatim.
#
# Without a `--`, every argument goes to the CLI, so `claude-box --resume xyz`
# keeps working.

# Working directory. Started anywhere inside ~/Projects (override with
# AGENT_BOX_PROJECTS), the box mounts the entire Projects dir at its real host
# path and starts in $PWD's real path. Sibling projects are then reachable
# (`../other-project`), and because the path matches the host, Claude Code /
# pi / opencode key their sessions and per-project settings the same way as
# the un-boxed CLIs, so history is shared between the two.
#
# That mount is not relabeled with :z: it would recursively rewrite the
# SELinux labels of the whole tree (tens of GB, possibly including other
# containers' data). The box runs with SELinux labeling disabled instead.
#
# Elsewhere $PWD is mounted at /work, as before.
#
# Started in $HOME itself, the box uses ~/tmp instead: mounting all of $HOME
# would expose every private file, and podman refuses to relabel $HOME with :z
# anyway ("SELinux relabeling of /home/... is not allowed"). Relative PATH
# arguments are still resolved against the real $PWD.
ABOX_PROJECTS=
ABOX_WORKDIR=/work
_abox_projects=$(readlink -f -- "${AGENT_BOX_PROJECTS:-$HOME/Projects}" || true)
_abox_pwd=$(readlink -f -- "$PWD")
if [ "$_abox_pwd" = "$(readlink -f -- "$HOME")" ]; then
  mkdir -p -- "$HOME/tmp"
  _abox_pwd=$(readlink -f -- "$HOME/tmp")
  echo "${0##*/}: started in \$HOME; using $_abox_pwd as the working directory" >&2
fi
# The host directory the box works in (normally the real $PWD).
ABOX_HOST_WORKDIR=$_abox_pwd
ABOX_WORK_MOUNTS=(-v "$_abox_pwd:/work:z")
if [ -n "$_abox_projects" ] && [ -d "$_abox_projects" ]; then
  case "$_abox_pwd/" in
    "$_abox_projects"/*)
      ABOX_PROJECTS=$_abox_projects
      ABOX_WORKDIR=$_abox_pwd
      ABOX_WORK_MOUNTS=(
        --security-opt label=disable
        -v "$ABOX_PROJECTS:$ABOX_PROJECTS"
      )
      ;;
  esac
fi
unset _abox_projects _abox_pwd

# Podman flags common to all three wrappers. The working directory is mounted
# here so it is the one mount every tool gets.
# -t only when there is a terminal: lets scripts and agents run a box
# non-interactively (podman refuses -t without one).
ABOX_TTY=(-i)
if [ -t 0 ] && [ -t 1 ]; then
  ABOX_TTY=(-it)
fi
ABOX_COMMON=(
  --rm "${ABOX_TTY[@]}"
  --userns=keep-id:uid=1000,gid=1000
  --security-opt no-new-privileges
  --cap-drop=ALL
  "${ABOX_WORK_MOUNTS[@]}"
  -w "$ABOX_WORKDIR"
  -e TERM
)

# Give the box read-only dnf lookups against the host's repos. dnf runs as the
# unprivileged user in the box, so it can search/query but never install.
#
# The repo config is copied, not bind-mounted: some host .repo files carry
# stray SELinux labels (e.g. user_tmp_t after being moved from /tmp) that
# container_t may not read, and relabeling /etc with :z is not an option. The
# copy lives under ~/.cache/agent-box/dnf and is only swapped out when the
# host's config changed, so concurrent boxes are not disturbed. The metadata
# cache (~100MB) persists there too, so lookups are fast after the first one.
abox_dnf_setup() {
  local me="${0##*/}" st="$HOME/.cache/agent-box/dnf" src dst tmp
  mkdir -p "$st/cache"
  for src in /etc/yum.repos.d /etc/pki/rpm-gpg; do
    dst="$st/${src##*/}"
    tmp=$(mktemp -d "$st/.stage.XXXXXX")
    if ! cp -rL -- "$src/." "$tmp/"; then
      echo "$me: warning: could not copy all of $src; dnf may miss repos" >&2
    fi
    if [ -d "$dst" ] && diff -qr -- "$tmp" "$dst" >/dev/null 2>&1; then
      rm -rf -- "$tmp"
    else
      rm -rf -- "$dst"
      mv -- "$tmp" "$dst"
    fi
  done
  ABOX_COMMON+=(
    -v "$st/yum.repos.d:/etc/yum.repos.d:ro,z"
    -v "$st/rpm-gpg:/etc/pki/rpm-gpg:ro,z"
    -v "$st/cache:/home/node/.cache/libdnf5:z"
  )
}

# Forward the host's ssh-agent socket, so git over SSH and ssh work from the
# box with whatever keys the agent holds. The key files themselves stay on the
# host; known_hosts and config are mounted read-only so host keys and host
# aliases match the host. Start with SSH_AUTH_SOCK= to leave the agent out.
abox_ssh_setup() {
  if [ ! -S "${SSH_AUTH_SOCK:-}" ]; then
    echo "$ABOX_ME: no ssh-agent (SSH_AUTH_SOCK); SSH keys unavailable in the box" >&2
    return 0
  fi
  local f
  ABOX_COMMON+=(
    # SELinux will not let container_t connect to a socket owned by a host
    # process (the agent), so labels have to be off.
    --security-opt label=disable
    -v "$SSH_AUTH_SOCK:/run/agent-box-ssh/agent.sock"
    -e SSH_AUTH_SOCK=/run/agent-box-ssh/agent.sock
  )
  for f in known_hosts config; do
    [ -f ~/.ssh/$f ] && ABOX_COMMON+=(-v "$HOME/.ssh/$f:/home/node/.ssh/$f:ro")
  done
  return 0
}

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

  local pwd_real=$ABOX_HOST_WORKDIR name dest real n
  local -A used=()

  for arg in "${paths[@]}"; do
    real=$(readlink -f -- "$arg" || true)
    if [ -z "$real" ] || [ ! -e "$real" ]; then
      echo "$me: no such path: $arg" >&2
      return 1
    fi
    # The working directory is already mounted; don't expose it twice.
    if [ "$real" = "$pwd_real" ]; then
      echo "$me: $arg is the working directory, already mounted at $ABOX_WORKDIR" >&2
      continue
    fi
    # Anything in Projects is already visible at its own path.
    if [ -n "$ABOX_PROJECTS" ]; then
      case "$real/" in
        "$ABOX_PROJECTS"/*)
          echo "$me: $real is already visible at the same path" >&2
          continue
          ;;
      esac
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

# ---------------------------------------------------------------------------
# Full box setup shared by all wrappers. A wrapper does:
#
#   abox_setup "$@"                  # wrapper flags, paths, everything common
#   ABOX_EXTRA+=(...)                # its own mounts and env
#   abox_run <command> [ARG...]      # run <command> in the box via abox-init
#
# Wrapper flags come first, in any order, before any paths:
#   --docker  a throwaway container engine for test containers
#   --shell   same box, but start bash instead of the tool; CLI args after
#             `--` go to bash (e.g. `opencode-box --shell -- -c 'make test'`)

ABOX_ME=${0##*/}
ABOX_DOCKER=0
ABOX_SHELL=0
# Extra podman flags; wrappers append their own.
ABOX_EXTRA=()
# Container name; defaults to <wrapper>-<pid>. claude-box overrides it.
ABOX_NAME=
# Name of a function the EXIT trap calls before the common cleanup.
ABOX_CLEANUP_HOOK=

_abox_proxy=
_abox_busdir=
_abox_dind=
_abox_dinddir=

abox_cleanup() {
  if [ -n "$ABOX_CLEANUP_HOOK" ]; then "$ABOX_CLEANUP_HOOK" || true; fi
  [ -n "$_abox_proxy" ] && kill "$_abox_proxy" 2>/dev/null
  [ -n "$_abox_busdir" ] && rm -rf -- "$_abox_busdir"
  [ -n "$_abox_dind" ] && podman rm -f -t 2 "$_abox_dind" >/dev/null 2>&1
  [ -n "$_abox_dinddir" ] && rm -rf -- "$_abox_dinddir"
  return 0
}

abox_setup() {
  while [ $# -gt 0 ]; do
    case $1 in
      --docker) ABOX_DOCKER=1 ;;
      --shell) ABOX_SHELL=1 ;;
      *) break ;;
    esac
    shift
  done
  abox_parse "$@"
  trap abox_cleanup EXIT

  abox_dnf_setup
  abox_ssh_setup
  abox_user_setup
  abox_tools_setup
  if ! abox_gnome_setup; then
    [ -n "$_abox_proxy" ] && kill "$_abox_proxy" 2>/dev/null
    _abox_proxy=
  fi
  if [ "$ABOX_DOCKER" -eq 1 ]; then abox_docker_setup; fi
  return 0
}

# --- Entry point and user ------------------------------------------------------
# Every box starts with abox-init (in the image) as root *of the box's user
# namespace* (not host root), with only the capabilities needed to drop to
# uid 1000 for good. It renames that user from the image's "node" to the host
# user name, so whoami and ssh's default login name match the host, and stays
# PID 1 to forward stop signals to the tool. See abox-init.
abox_user_setup() {
  ABOX_EXTRA+=(
    --user 0:0
    --cap-add=SETUID,SETGID,SETPCAP
    -e HOME=/home/node
    -e "ABOX_HOST_USER=$(id -un)"
  )
}

# --- gh and mise -----------------------------------------------------------------
# Persistent state for tools in the image, shared by all boxes and kept apart
# from any host install: gh's login, mise's installed tools and cache.
abox_tools_setup() {
  mkdir -p ~/.local/share/agent-box/mise ~/.cache/agent-box/mise ~/.config/agent-box/gh
  ABOX_EXTRA+=(
    -v "$HOME/.local/share/agent-box/mise:/home/node/.local/share/mise:z"
    -v "$HOME/.cache/agent-box/mise:/home/node/.cache/mise:z"
    -v "$HOME/.config/agent-box/gh:/home/node/.config/gh:z"
    -e MISE_GITHUB_TOKEN
    -e GH_TOKEN
  )
}

# --- GNOME extension management (always on) ------------------------------------
# The agent can list/enable/disable/install/pack the host's GNOME Shell
# extensions and use gsettings. Skipped with a warning when there is no
# session bus, e.g. over ssh.
abox_gnome_setup() {
  if ! command -v xdg-dbus-proxy >/dev/null; then
    echo "$ABOX_ME: xdg-dbus-proxy not found; GNOME extension access disabled" >&2
    return 1
  fi
  if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    echo "$ABOX_ME: no session bus; GNOME extension access disabled" >&2
    return 1
  fi

  # Filtered view of the session bus: only GNOME Shell's extension API and
  # dconf (so gsettings writes work) are visible. The keyring, systemd --user,
  # portals, notifications etc. are not reachable from the box.
  _abox_busdir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/agent-box-bus.XXXXXX")
  mkfifo "$_abox_busdir/sync"
  # Read end held by us (and inherited by podman). The proxy writes one byte
  # once it is listening, and exits when every holder of the read end is gone,
  # so it cannot outlive the session even if the wrapper is killed.
  exec {_abox_sync}<>"$_abox_busdir/sync"
  xdg-dbus-proxy --fd=3 "$DBUS_SESSION_BUS_ADDRESS" "$_abox_busdir/bus" \
    --filter \
    --talk=org.gnome.Shell.Extensions \
    --talk=ca.desrt.dconf \
    3>"$_abox_busdir/sync" &
  _abox_proxy=$!
  if ! read -r -n 1 -t 5 -u "$_abox_sync" _; then
    echo "$ABOX_ME: xdg-dbus-proxy failed to start; GNOME extension access disabled" >&2
    return 1
  fi

  mkdir -p ~/.local/share/gnome-shell/extensions ~/.config/dconf
  ABOX_EXTRA+=(
    # SELinux will not let container_t connect to a socket owned by a host
    # (unconfined_t) process, so the bus is unreachable with labels on.
    --security-opt label=disable
    -v "$_abox_busdir:/run/agent-box-bus"
    -e DBUS_SESSION_BUS_ADDRESS=unix:path=/run/agent-box-bus/bus
    # Installed extensions, read-write.
    -v "$HOME/.local/share/gnome-shell/extensions:/home/node/.local/share/gnome-shell/extensions"
    # gsettings reads the dconf db directly; writes go over the bus.
    -v "$HOME/.config/dconf:/home/node/.config/dconf:ro"
    # The host's compiled schemas, so gsettings knows org.gnome.shell etc. at
    # the host's GNOME version.
    -v /usr/share/glib-2.0/schemas:/usr/share/glib-2.0/schemas:ro
    -v /usr/share/gnome-shell/extensions:/usr/share/gnome-shell/extensions:ro
    # Lets the gnome-extensions shim map host paths the shell reports.
    -e "ABOX_HOST_HOME=$HOME"
  )
}

# --- Docker (--docker) ------------------------------------------------------------
# A sidecar container runs podman's Docker-compatible API ("docker in
# docker"). Containers the agent starts live inside the sidecar, not on the
# host engine: they cannot see host paths beyond the ones the box already has,
# nor your own containers and images. Everything, images included, is
# discarded when the session ends.
ABOX_DIND_IMAGE=quay.io/podman/stable:latest
abox_docker_setup() {
  _abox_dinddir=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/agent-box-docker.XXXXXX")
  mkdir "$_abox_dinddir/sock"
  # The image disables cgroups for nested containers, which makes podman's
  # Docker-compat build endpoint fail ("cannot set cgroup parent").
  printf '[containers]\ncgroups = "enabled"\n' >"$_abox_dinddir/containers.conf"
  _abox_dind="agent-box-docker-${_abox_dinddir##*.}"
  echo "$ABOX_ME: starting docker sidecar ($_abox_dind)" >&2
  # --privileged is needed to nest containers; under rootless podman it only
  # grants privileges inside your user namespace. Same working-dir and /mnt
  # mounts as the box, so `docker run -v <path>:...` resolves to the same
  # files.
  if ! podman run -d --rm --name "$_abox_dind" \
      --privileged --device /dev/fuse \
      -v "$_abox_dinddir/containers.conf:/etc/containers/containers.conf.d/99-agent-box.conf:ro,z" \
      -v "$_abox_dinddir/sock:/run/agent-box-docker:z" \
      "${ABOX_WORK_MOUNTS[@]}" "${ABOX_MOUNTS[@]}" \
      "$ABOX_DIND_IMAGE" \
      podman system service --time=0 unix:///run/agent-box-docker/docker.sock \
      >/dev/null; then
    echo "$ABOX_ME: failed to start the docker sidecar" >&2
    exit 1
  fi
  local i
  for i in $(seq 100); do
    [ -S "$_abox_dinddir/sock/docker.sock" ] && break
    sleep 0.2
  done
  if [ ! -S "$_abox_dinddir/sock/docker.sock" ]; then
    echo "$ABOX_ME: docker sidecar did not come up; logs:" >&2
    podman logs "$_abox_dind" >&2 || true
    exit 1
  fi
  ABOX_EXTRA+=(
    # The socket belongs to another container's process; SELinux would block
    # the connection with labels on.
    --security-opt label=disable
    -v "$_abox_dinddir/sock:/run/agent-box-docker"
    -e DOCKER_HOST=unix:///run/agent-box-docker/docker.sock
    -e CONTAINER_HOST=unix:///run/agent-box-docker/docker.sock
  )
}

# --- Run ------------------------------------------------------------------------------
# Runs `abox-init COMMAND ARG...` in the box. Not exec: the EXIT trap has to
# run to stop the proxy/sidecar and clean up.
abox_run() {
  # Named, so that if the wrapper is terminated (or its terminal closes) it
  # can stop its own container instead of leaving it running unattended; the
  # EXIT trap then cleans up as usual.
  _abox_name=${ABOX_NAME:-$ABOX_ME-$$}
  trap 'podman stop -t 10 "$_abox_name" >/dev/null 2>&1; exit 143' TERM HUP
  podman run "${ABOX_COMMON[@]}" "${ABOX_MOUNTS[@]}" "${ABOX_EXTRA[@]}" \
    --name "$_abox_name" \
    --hostname "$ABOX_ME" \
    agent-box:latest abox-init "$@"
}
