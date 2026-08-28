# claude-box

Run coding-agent CLIs (Claude Code, opencode, pi) inside a rootless Podman
container, so each only ever sees the directories you hand it.

One shared image, one wrapper per tool:

- `Containerfile` — `node:24-slim` + `git`, `ripgrep`, `jq`, `less`, `zstd`,
  plus `@earendil-works/pi-coding-agent` (npm), the opencode binary and the
  Claude Code native build (both official installers). Runs as the unprivileged
  `node` user; no entrypoint, the wrapper selects the binary. A build-time
  smoke test runs `--version` for all three so a broken install fails the
  build.
- `claude-box` — runs `claude`, bind-mounts your host `~/.claude` /
  `~/.claude.json` so config and auth persist, plus the native install dirs so
  Claude Code can update itself (see below).
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
