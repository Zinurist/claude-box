# claude-box

Run Claude Code inside a rootless Podman container, so it only ever sees the
directory you launch it from.

## Files

- `Containerfile` — `node:24-slim` + `git`, `ripgrep`, `jq`, `less`, and the
  `@anthropic-ai/claude-code` CLI. Runs as the unprivileged `node` user with
  `claude` as the entrypoint.
- `claude-box` — wrapper script. Runs the image with `--userns=keep-id`,
  `--cap-drop=ALL` and `no-new-privileges`, bind-mounts `$PWD` at `/work` and
  your host `~/.claude` / `~/.claude.json` so config and auth persist.
- `install.sh` — builds the image and installs the wrapper to
  `~/.local/bin/claude-box`.

## Usage

```sh
./install.sh          # build image + install wrapper
cd ~/some/project
claude-box            # any args are passed through to claude
```

Requires `podman` and `~/.local/bin` on your `PATH`.
