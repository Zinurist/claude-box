# claude-box

Run coding-agent CLIs (Claude Code, opencode, pi) inside a rootless Podman
container, so each only ever sees the directories you hand it.

One shared image, one wrapper per tool:

- `Containerfile` — `fedora:44` (matching the host) + Node 24, `git`,
  `ripgrep`, `jq`, `less`, `zstd`, GLib/dconf tooling, plus
  `@earendil-works/pi-coding-agent` (npm), the opencode binary and the Claude
  Code native build (both official installers). Runs as the unprivileged
  `node` user (uid 1000); no entrypoint, the wrapper selects the binary. A
  build-time smoke test runs `--version` for all three so a broken install
  fails the build.
- `claude-box` — runs `claude`, bind-mounts your host `~/.claude` /
  `~/.claude.json` so config and auth persist, plus the native install dirs so
  Claude Code can update itself (see below).
- `gnome-extensions` — in-image D-Bus replacement for GNOME's CLI, used by
  `claude-box` for extension management (see below).
- `claude-launch` — in-image launcher that seeds and selects the Claude Code
  binary; not used on the host.
- `opencode-box` — runs `opencode`, bind-mounts `~/.config/opencode` (config),
  `~/.local/share/opencode` (auth, db, sessions) and `~/.cache/opencode`
  (helper binaries opencode downloads at startup).
- `pi-box` — runs `pi`, bind-mounts `~/.pi` (settings, auth, models,
  sessions).
- Each wrapper uses `--userns=keep-id:uid=1000,gid=1000`, `--cap-drop=ALL` and
  `no-new-privileges`, mounts `$PWD` as `/work`, and forwards any provider API
  keys that are set in your environment.
- `agent-box-lib.sh` — shared argument parsing and the common podman flags,
  sourced by all three wrappers.
- `install.sh` — builds the image, installs the wrappers (and the shared
  lib) to `~/.local/bin/`, and maintains the shell aliases in `~/.bashrc`.

## Usage

```sh
./install.sh            # build image + install all three wrappers
cd ~/some/project
claude-box              # any args are passed through to the CLI
opencode-box run ...
pi-box
```

Requires `podman` and `~/.local/bin` on your `PATH`.

### Exposing extra directories

`$PWD` is always mounted at `/work` and is the working directory. To let the
agent see more of the host, list those paths first and separate them from the
CLI's own arguments with `--`:

```
<tool>-box [PATH...] [-- CLI_ARG...]
```

Each path is mounted read-write at `/mnt/<basename>`:

```sh
cd ~/Projects/app
claude-box ../lib ~/notes -- --resume xyz
# ~/Projects/app -> /work   (working directory)
# ~/Projects/lib -> /mnt/lib
# ~/notes        -> /mnt/notes
# runs: claude --resume xyz
```

The wrapper prints each mapping to stderr as it starts, so you can tell the
agent where to look. Duplicate basenames get a numeric suffix (`/mnt/lib-2`),
and a path that does not exist is a hard error before the container starts.

Without a `--`, every argument goes straight to the CLI and nothing extra is
mounted — so `claude-box --resume xyz` still works as before.

## Package lookups with dnf

Every box can run `dnf search`, `dnf info`, `dnf provides` and
`dnf repoquery` against the **host's** repositories (Fedora, RPM Fusion and the
third-party repos in `/etc/yum.repos.d`). Installing is impossible: dnf runs
as the unprivileged user without capabilities, and `dnf install` fails with
"requires superuser privileges".

The wrappers keep this under `~/.cache/agent-box/dnf`:

- `yum.repos.d/`, `rpm-gpg/` — copies of the host's repo config and keys,
  refreshed at launch when the host's files changed. They are copied rather
  than bind-mounted because some host `.repo` files can carry stray SELinux
  labels (e.g. `user_tmp_t` after being moved from `/tmp`) that a container
  may not read, and relabeling `/etc` is not an option;
- `cache/` — dnf's metadata cache (~100MB), shared by all boxes, so only the
  first lookup downloads.

Repos that verify metadata with a remote key (Tailscale) need the key
accepted once. Run `dnf -y makecache` inside a box; the key is stored in the
shared cache. Without that, dnf skips the repo with a signature warning.

The image's Fedora release must match the host's for lookups to be accurate.
After a host upgrade, bump the `FROM` line and re-run `./install.sh`.

## Managing GNOME extensions

`claude-box` always lets Claude manage the host's GNOME Shell extensions. To
do that, it:

- starts an `xdg-dbus-proxy` on the host that exposes **only**
  `org.gnome.Shell.Extensions` and `ca.desrt.dconf` from your session bus.
  The keyring, `systemd --user`, portals, notifications etc. stay unreachable.
  The proxy exits with the session;
- mounts `~/.local/share/gnome-shell/extensions` read-write at the same place
  in the container, plus the system extensions dir read-only;
- mounts `~/.config/dconf` read-only (gsettings reads the db file directly;
  writes go over the bus) and the host's `/usr/share/glib-2.0/schemas`, so
  `gsettings` sees the host GNOME version's schemas;
- runs with `--security-opt label=disable`, because SELinux does not let a
  `container_t` process connect to a socket owned by a host process.

Without a session bus (e.g. over ssh) or without `xdg-dbus-proxy`, this part
is skipped with a warning and the box starts without it.

The image has `gdbus`, `gsettings`, `glib-compile-schemas`, `msgfmt`, `zip`
and a `gnome-extensions` replacement (`gnome-extensions` in this repo). The
real CLI comes in the gnome-shell package, which pulls in mutter, gjs and more.
The replacement talks to the running shell over D-Bus and supports `list`
(with the usual filters), `info`/`show`, `enable`, `disable`, `reset`,
`uninstall`, `prefs`, `install` and `pack`. It also adds `errors UUID`,
which prints the errors the shell recorded for an extension. For extension
work, start the box in the checkout (`cd ~/Projects/my-ext && claude-box`)
or pass the checkout as a path.

On Wayland the shell only discovers newly installed extensions at login, and
a loaded extension keeps its old code until then. The box cannot get around
that; test changes in a nested shell on the host or by logging out and back
in.

What this exposes: all of dconf is readable (app settings, recent folders,
sometimes API keys extensions store in their settings) and writable, since
the bus filter cannot narrow writes to specific keys. An extension the agent
installs and enables runs as you inside gnome-shell after your next login.

## Docker (`--docker`)

```sh
claude-box --docker [PATH...] [-- CLI_ARG...]
```

`--docker` (must be the first argument) gives Claude a throwaway container
engine for building and running test containers, e.g. to check that this
repo's Containerfile builds. It is docker-in-docker, not your host's engine:

- a sidecar container (`quay.io/podman/stable`, pulled on first use) runs
  `podman system service`, which serves the Docker API. It runs
  `--privileged`, which under rootless podman only means privileged within
  your user namespace;
- the box gets `DOCKER_HOST` and `CONTAINER_HOST` pointing at it, and has the
  `docker`, `docker compose` and `podman` (remote) clients;
- the sidecar mounts the same `/work` and `/mnt/...` paths as the box, so
  `docker run -v /work:/src ...` sees the same files. Containers cannot reach
  any other host path, nor your Docker CE or podman containers and images;
- the sidecar, and every image and container in it, is deleted when the
  session ends, so each session starts with an empty image cache.

`docker build` uses Docker's classic builder (the image deliberately leaves
out buildx), which podman serves directly; expect a deprecation warning.

## mise

[mise](https://mise.jdx.dev) (mise-en-place) is in the image and its shims
are on `PATH`, so tools it installs work in Claude's non-interactive shells
without `mise activate`. `claude-box` persists its data separately from any
host install of mise:

| host | container |
|---|---|
| `~/.local/share/agent-box/mise` | `~/.local/share/mise` (installed tools) |
| `~/.cache/agent-box/mise` | `~/.cache/mise` |

mise's state, including which config files are trusted, is not persisted.
Every project is mounted at `/work`, so a persisted trust for
`/work/mise.toml` would carry over to every other project. The global config
(`~/.config/mise`) is not persisted either; project `mise.toml` files are the
way to pin tools. Set `MISE_GITHUB_TOKEN` on the host to avoid GitHub rate
limits; it is passed through when set. mise itself is updated by rebuilding
the image.

## Claude Code auto-updates

An npm global install cannot update itself here: it lives in root-owned
`/usr/local`, the container runs as `node`, and Claude Code reports
`Auto-update failed: no write permission to npm prefix`. The image therefore
uses the **native** install instead — a single versioned binary that lives
entirely under `$HOME`:

```
~/.local/share/claude/versions/<version>   the binary itself
~/.local/bin/claude                        symlink to the active version
~/.cache/claude/staging                    download staging for updates
```

`claude-box` mounts the two writable ones from the host, keyed to agent-box
so they stay separate from your own host install:

| host | container |
|---|---|
| `~/.local/share/agent-box/claude` | `~/.local/share/claude` |
| `~/.cache/agent-box/claude` | `~/.cache/claude` |

Both sit on the same host filesystem, so the updater's
staging-to-versions rename stays on one device.

The symlink is not mounted — it lives in the container and is rebuilt on
every run by `claude-launch`, which:

1. copies any version from the image's `/opt/claude-seed` that the volume
   does not already have, so the first run costs no download and a rebuilt
   image is picked up immediately;
2. symlinks `~/.local/bin/claude` to the highest version present (`sort -V`),
   skipping empty or non-executable files left by an interrupted update,
   which is how a version the auto-updater installed in an earlier session
   gets used;
3. execs it with your arguments.

`claude doctor` inside the box should report `Running: native` and
`Auto-updates: enabled`.

## Notes

- The container resolves hostnames via its own DNS. If your opencode config
  points at a local server by hostname (e.g. `http://myhost:11434/v1`), either
  use the IP/LAN address or add `--network host` to the `opencode-box`
  invocation.
- Mounting `~/.config/opencode` also mounts any `node_modules` from bun-based
  plugins; if a plugin fails to load in-container, run opencode once outside
  the box to reinstall its dependencies for the container's platform.
- Paths under `/mnt` do not match their host paths, so a session that refers to
  them is not portable outside the box.
- Every project is mounted at the same path, `/work`. Both pi and Claude Code
  key their session/project history off the working directory, so history from
  different host projects lands in the same bucket (`~/.pi/agent/sessions/`,
  `~/.claude/projects/-work/`). Harmless, but `--continue`/`--resume` will
  offer sessions from other projects.
- Only Claude Code auto-updates inside the box. `pi update self` and
  opencode's updater still write to root-owned `/usr/local`, so those two
  are updated by rebuilding the image (`./install.sh`).
- `git` is available in the image but your `~/.gitconfig` is not mounted, so
  in-container commits need `user.name`/`user.email` set in the repo (or add a
  read-only mount for it).

## Shell aliases

`install.sh` maintains a marked block at the end of `~/.bashrc`:

```sh
# >>> agent-box >>>
alias claude='claude-box'
alias claude-raw='/home/you/.local/bin/claude'
alias opencode='opencode-box'
alias opencode-raw='/home/you/.opencode/bin/opencode'
alias pi='pi-box'
alias pi-raw='/home/you/.nvm/versions/node/v24.6.0/bin/pi'
# <<< agent-box <<<
```

So the plain names run boxed, and `<tool>-raw` reaches the real binary. The
`-raw` paths are resolved at install time from `PATH` (falling back to the
usual install locations), so re-run `./install.sh` after a node/nvm upgrade
moves `pi`. If a tool isn't installed on the host, its `-raw` alias is skipped
with a warning rather than pointing at nothing.

The block is rewritten in place on every run, and any hand-written
`alias claude=` / `alias pi-raw=` style lines elsewhere in the file are removed
so they can't shadow it. The pre-install file is kept as
`~/.bashrc.agent-box.bak` (written once, never clobbered by later runs).

Pass `--no-bashrc` to install the wrappers without touching your shell config,
or set `BASHRC=/path/to/file` to target a different rc file.
