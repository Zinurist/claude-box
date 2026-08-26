# claude-box

Run coding-agent CLIs (Claude Code, opencode, pi) inside a rootless Podman
container, so each only ever sees the directory you launch it from.

One shared image, one wrapper per tool:

- `Containerfile` — `node:24-slim` + `git`, `ripgrep`, `jq`, `less`, plus
  `@anthropic-ai/claude-code`, `@earendil-works/pi-coding-agent` (npm) and the
  opencode binary (official installer). Runs as the unprivileged `node` user;
  no entrypoint, the wrapper selects the binary.
- `claude-box` — runs `claude`, bind-mounts `$PWD` at `/work` and your host
  `~/.claude` / `~/.claude.json` so config and auth persist.
- `opencode-box` — runs `opencode`, bind-mounts `~/.config/opencode` (config)
  and `~/.local/share/opencode` (auth, db, sessions).
- `pi-box` — runs `pi`, bind-mounts `~/.pi` (settings, auth, models,
  sessions).
- Each wrapper uses `--userns=keep-id`, `--cap-drop=ALL` and
  `no-new-privileges`, and passes `$PWD` through as `/work`.
- `install.sh` — builds the image and installs the wrappers to
  `~/.local/bin/`.

## Usage

```sh
./install.sh            # build image + install all three wrappers
cd ~/some/project
claude-box              # any args are passed through to the CLI
opencode-box run ...
pi-box
```

Requires `podman` and `~/.local/bin` on your `PATH`.

## Notes

- The container resolves hostnames via its own DNS. If your opencode config
  points at a local server by hostname (e.g. `http://myhost:11434/v1`), either
  use the IP/LAN address or add `--network host` to the `opencode-box`
  invocation.
- Mounting `~/.config/opencode` also mounts any `node_modules` from bun-based
  plugins; if a plugin fails to load in-container, run opencode once outside
  the box to reinstall its dependencies for the container's platform.
