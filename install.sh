#!/bin/sh
set -eu
podman build -t agent-box .
for tool in claude opencode pi; do
  cp "$tool-box" "$HOME/.local/bin/$tool-box"
  chmod +x "$HOME/.local/bin/$tool-box"
done
echo "installed: claude-box, opencode-box, pi-box"
