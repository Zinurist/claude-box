# claude-box

Run coding-agent CLIs (Claude Code, opencode, pi) inside a rootless Podman
container, so each only ever sees the directories you hand it.

> [!WARNING]
> **This project is vibe coded** — I wrote it largely with an AI coding assistant.
>
> It is **tailored to my own setup**: Fedora with GNOME on Wayland, rootless Podman, SELinux
> enforcing, my projects in `~/Projects`, and the particular access I'm comfortable giving an
> agent (e.g. GNOME extension management, all of `~/Projects`, full network). It is not a
> general-purpose or hardened sandbox. **Don't use it as is.** Treat it as a starting point and
> have an AI adapt it to your own system and threat model.

One shared image, one wrapper per tool:

- `Containerfile` — `fedora:44` (matching the host) + Node 24, `git`,
  `ripgrep`, `jq`, `less`, `zstd`, `ffmpeg` (RPM Fusion), `wl-clipboard`, GLib/dconf tooling, plus
  `@earendil-works/pi-coding-agent` (npm), the opencode binary and the Claude
  Code native build (both official installers). Runs as the unprivileged
  `node` user (uid 1000); no entrypoint, the wrapper selects the binary. A
  build-time smoke test runs `--version` for all three so a broken install
  fails the build.
- `claude-box` — runs `claude`, bind-mounts your host `~/.claude` /
  `~/.claude.json` so config and auth persist, plus the native install dirs so
  Claude Code can update itself (see below).
- `gnome-extensions` — in-image D-Bus replacement for GNOME's CLI, used for
  extension management (see below).
- `abox-init` — in-image entry point for every box: renames the box user to
  your host user name, gives Claude a host-unique PID for peer sessions
  (`claude-box` only), drops all privileges, and stays PID 1 to forward stop
  signals to the tool (see below).
- `claude-launch` — in-image launcher that seeds and selects the Claude Code
  binary; not used on the host.
- `opencode-box` — runs `opencode`, bind-mounts `~/.config/opencode` (config),
  `~/.local/share/opencode` (auth, db, sessions), `~/.local/state/opencode`
  (last-used models, prompt history) and `~/.cache/opencode`. Defaults to
  the `zinufgame-llama/qwen3.8-27b-128k` model (`OPENCODE_BOX_MODEL` to
  change, empty for none) via `OPENCODE_CONFIG_CONTENT`
  (helper binaries opencode downloads at startup). If the host has opencode in
  `~/.opencode/bin`, that binary is mounted read-only over the image's copy, so
  the box always runs the version you installed on the host.
- `pi-box` — runs `pi`, bind-mounts `~/.pi` (settings, auth, models,
  sessions).
- Each wrapper uses `--userns=keep-id:uid=1000,gid=1000`, `--cap-drop=ALL` and
  `no-new-privileges`, mounts the working directory (see below), and forwards any provider API
  keys that are set in your environment.
- `agent-box-lib.sh` — everything the boxes share: wrapper flags and argument
  parsing, the common podman flags, dnf, ssh-agent, GNOME, `--docker`, gh and
  mise. Sourced by all three wrappers, which only add their tool's own state
  (and, for `claude-box`, peer sessions).
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

Everything below applies to all three boxes unless it says `claude-box`.

Requires `podman` and `~/.local/bin` on your `PATH`.

### Working directory and `~/Projects`

Started anywhere inside `~/Projects`, a box mounts **all of `~/Projects`**
read-write at its real host path (`/home/you/Projects`) and starts in the
same directory you are in. So:

- sibling projects work as-is: from `~/Projects/app`, "look at
  `../lib`" just works;
- the path in the box matches the host, and Claude Code, pi and opencode key
  sessions and per-project settings off the working directory. Boxed and
  un-boxed runs therefore share history: `claude --resume` on the host offers
  sessions started in the box and vice versa.

That mount is not relabeled for SELinux (`:z` would recursively rewrite the
labels of the whole tree, possibly including other containers' data), so
those boxes run with `--security-opt label=disable`. Set `AGENT_BOX_PROJECTS`
to use a different directory than `~/Projects`.

Started anywhere else, `$PWD` is mounted at `/work` and is the working
directory, as before. Started in `$HOME` itself, the box uses `~/tmp` as the
working directory instead (all of `$HOME` is never mounted, and podman refuses
to relabel it anyway).

### Exposing extra directories

To let the agent see more of the host, list those paths first and separate them from the
CLI's own arguments with `--`:

```
<tool>-box [PATH...] [-- CLI_ARG...]
```

Each path is mounted read-write at `/mnt/<basename>`:

```sh
cd ~/Projects/app
claude-box ~/notes ~/Downloads/data -- --resume xyz
# ~/Projects     -> same path (working directory: ~/Projects/app)
# ~/notes        -> /mnt/notes
# ~/Downloads/data -> /mnt/data
# runs: claude --resume xyz
```

The wrapper prints each mapping to stderr as it starts, so you can tell the
agent where to look. Duplicate basenames get a numeric suffix (`/mnt/lib-2`),
and a path that does not exist is a hard error before the container starts.
Paths inside `~/Projects` are skipped when the box is already in Projects
mode, since they are visible at their own path.

Without a `--`, every argument goes straight to the CLI and nothing extra is
mounted — so `claude-box --resume xyz` still works as before.

## Talking to other Claude sessions

Claude sessions on this machine can find and message each other (ListAgents
/ SendMessage): box to box, box to host and host to box. Each box still has
its own PID namespace, so it sees none of the host's or other boxes'
processes.

Claude registers each session as `~/.claude/sessions/<pid>.json` with a Unix
socket at `<socket dir>/<pid>.sock`. It reaches sessions in other PID
namespaces through those sockets, so two things are needed:

- **A shared socket dir.** `claude-box` mounts the host's
  `$XDG_RUNTIME_DIR/cc-socks` (or `/tmp/cc-socks-<uid>` without
  `XDG_RUNTIME_DIR`) at the same path and sets `XDG_RUNTIME_DIR` to match.
  Sockets are owned by other processes, so the box runs with
  `--security-opt label=disable`.
- **A unique PID.** In a plain box Claude would always be PID 1, so every box
  would claim `1.json` and `1.sock`. The wrapper picks a random PID that is
  free on the host (not a running process, no existing session file or
  socket). The box then starts with `abox-init` as root *of its own user
  namespace* (not host root), with only `SYS_ADMIN`, `SETUID`, `SETGID` and
  `SETPCAP` and a writable `/proc/sys`. It writes the PID to
  `/proc/sys/kernel/ns_last_pid`, then drops to the `node` user with every
  capability set empty (`no-new-privileges` is on as always) and forks
  Claude, which gets that PID. Nothing privileged keeps running. The
  narrower `CHECKPOINT_RESTORE` capability would suffice, but SELinux denies
  it to unlabeled (`spc_t`) containers.

A host PID could in theory be handed to a new host Claude session while a box
holds the same number. Then the two would overwrite each other's session
entry. With a few sessions and a random pick from ~4 million PIDs, that's
very unlikely.

This is Claude Code–specific, so only `claude-box` does it. If a box is
killed hard, the wrapper removes the session entry it left (only box entries,
recognisable by their empty machine ID in `pidDomain`).

In every box, `abox-init` is PID 1 and forwards stop signals to the tool, so
`podman stop` and closing the terminal shut it down cleanly. If the wrapper
itself is terminated, it stops its container (named `<tool>-box-<pid>`; for
`claude-box` the pid is Claude's).

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

Every box always lets the agent manage the host's GNOME Shell extensions. To
do that, the wrapper:

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

## Shell (`--shell`)

```sh
<tool>-box --shell [--docker] [PATH...] [-- BASH_ARG...]
```

Starts the same box (mounts, GNOME access, dnf, mise, and the docker
sidecar if `--docker` is given) but runs `bash` instead of the tool, for
poking around or debugging the box. The tool still works inside it (in
`claude-box`, `claude` is seeded and linked first).
Arguments after `--` go to bash, so it also runs one-off commands:

```sh
claude-box --shell -- -c 'dnf provides /usr/bin/gnome-extensions'
echo 'mise ls' | claude-box --shell
```

The wrapper flags (`--shell`, `--docker`) come first, in any order, before
any paths. All wrappers only allocate a TTY (`-t`) when stdin and stdout are
terminals, so they also work from scripts and agents.

## Docker (`--docker`)

```sh
<tool>-box --docker [PATH...] [-- CLI_ARG...]
```

`--docker` gives the agent a throwaway container
engine for building and running test containers, e.g. to check that this
repo's Containerfile builds. It is docker-in-docker, not your host's engine:

- a sidecar container (`quay.io/podman/stable`, pulled on first use) runs
  `podman system service`, which serves the Docker API. It runs
  `--privileged`, which under rootless podman only means privileged within
  your user namespace;
- the box gets `DOCKER_HOST` and `CONTAINER_HOST` pointing at it, and has the
  `docker`, `docker compose` and `podman` (remote) clients;
- the sidecar mounts the same working directory (`~/Projects` or `/work`)
  and `/mnt/...` paths as the box, so `docker run -v "$PWD:/src" ...` sees the
  same files. Containers cannot reach
  any other host path, nor your Docker CE or podman containers and images;
- the sidecar, and every image and container in it, is deleted when the
  session ends, so each session starts with an empty image cache.

`docker build` uses Docker's classic builder (the image deliberately leaves
out buildx), which podman serves directly; expect a deprecation warning.

## GitHub CLI

`gh` is in the image. The boxes give it their own persistent config dir,
`~/.config/agent-box/gh` on the host, shared by all three, so log in once
from a box and it sticks:

```sh
claude-box --shell -- -c 'gh auth login'
```

Alternatively, a `GH_TOKEN` set on the host is passed through. Whatever token
you give it, the agent can do with it what the token allows (comment, open PRs,
push via the API), so prefer a fine-grained token scoped to the repos you
want. SSH remotes work through the forwarded ssh-agent (see below).

## SSH agent

All three boxes forward the host's ssh-agent (`$SSH_AUTH_SOCK`, on GNOME the
gcr agent), so `git` over SSH and `ssh` work with whatever keys the agent
holds. The key files are never mounted; `~/.ssh/known_hosts` and
`~/.ssh/config` are, read-only, so host keys and host aliases match the host.

The box user (uid 1000, image name `node`) is also renamed to your host user
name at start, so `ssh host` logs in as you, as on the host; its home stays
`/home/node`.

This means the agent can push to, or log in to, anything your loaded keys can
reach. To narrow that, load only the keys you want into the agent, or start
a box with `SSH_AUTH_SOCK=` to leave the agent out. Without an agent
the box starts as before, with a warning.

New hosts can't be added to the read-only `known_hosts`; connect once from
the host first.

## Clipboard

Every box gets the host's Wayland socket (`$WAYLAND_DISPLAY`) and the image
has `wl-clipboard`, so copying text out of Claude Code / opencode / pi and
pasting images into them works. Without it the tools fall back to the OSC 52
escape code, which VTE terminals (GNOME Terminal, ddterm) ignore, so "copied
to clipboard" would copy nothing. The socket belongs to gnome-shell, so this
needs `--security-opt label=disable` like the other host sockets.

Start a box with `WAYLAND_DISPLAY=` to leave it out.

opencode 2 is the exception: it copies its own selections only via OSC 52,
never `wl-copy`, so in a VTE terminal its "copied to clipboard" copies
nothing (boxed or not). `opencode-box` therefore turns opencode's mouse
capture off (`{"mouse":false}` via `OPENCODE_CLI_CONFIG_CONTENT`): the
terminal selects, and Ctrl+Shift+C copies, as with Claude Code. That costs
opencode's own mouse handling (clicks, wheel scrolling); start with
`OPENCODE_BOX_MOUSE=1` to keep it, and Shift+drag to select natively.

## mise

[mise](https://mise.jdx.dev) (mise-en-place) is in the image and its shims
are on `PATH`, so tools it installs work in Claude's non-interactive shells
without `mise activate`. The boxes persist its data, shared by all three and
separate from any host install of mise:

| host | container |
|---|---|
| `~/.local/share/agent-box/mise` | `~/.local/share/mise` (installed tools) |
| `~/.cache/agent-box/mise` | `~/.cache/mise` |

mise's state, including which config files are trusted, is not persisted.
Outside `~/Projects` every directory is mounted at `/work`, so a persisted
trust for `/work/mise.toml` would carry over to every other one. The global config
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
- Outside `~/Projects`, every directory is mounted at the same path, `/work`.
  Both pi and Claude Code key their session/project history off the working
  directory, so history from those directories lands in the same bucket
  (`~/.pi/agent/sessions/`, `~/.claude/projects/-work/`). Harmless, but
  `--continue`/`--resume` will offer sessions from other directories. Inside
  `~/Projects` this does not apply (see above).
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
