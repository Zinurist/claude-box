FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ripgrep jq less zstd ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# npm >= 11.17 skips lifecycle scripts unless explicitly allowed. This is the
# exact package list npm itself suggests for this install; without it npm only
# warns, so the build would still "succeed" with scripts skipped.
RUN npm install -g --allow-scripts=@google/genai,protobufjs \
      @earendil-works/pi-coding-agent

# opencode ships as a single static binary; official installer drops it in
# $HOME/.opencode/bin, move it into the PATH for the unprivileged user.
RUN curl -fsSL https://opencode.ai/install | bash \
 && install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
 && rm -rf /root/.opencode

# Claude Code uses its *native* install, not the npm one: an npm global install
# lives in root-owned /usr/local, and the auto-updater then fails with "no write
# permission to npm prefix" for the unprivileged user. The native install is a
# single versioned binary under ~/.local/share/claude/versions, which claude-box
# mounts from the host so updates survive `podman run --rm`.
#
# This runs as root, so keep the binary only as a read-only seed that
# claude-launch copies into the mounted volume when that volume is missing it.
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && mkdir -p /opt/claude-seed \
 && cp /root/.local/share/claude/versions/* /opt/claude-seed/ \
 && chmod 0755 /opt/claude-seed/* \
 && for v in /opt/claude-seed/*; do "$v" --version; done \
 && rm -rf /root/.local /root/.cache /root/.claude

COPY claude-launch /usr/local/bin/claude-launch

# Fail the build loudly if the npm/opencode installs didn't produce a working
# binary (e.g. the --allow-scripts list above drifted, which npm only warns
# about). The claude seed is checked in its own layer above.
RUN pi --version && opencode --version

# Pre-create XDG dirs for the unprivileged user: podman auto-creates missing
# mount parents as root, which would make e.g. /home/node/.local/state
# unwritable by opencode.
RUN mkdir -p /home/node/.config /home/node/.cache /home/node/.local/bin \
      /home/node/.local/share /home/node/.local/state \
 && chown -R node:node /home/node/.config /home/node/.cache /home/node/.local

USER node
WORKDIR /work
# claude-launch symlinks the version it picked into ~/.local/bin.
ENV PATH=/home/node/.local/bin:$PATH
# No ENTRYPOINT: each wrapper (claude-box, opencode-box, pi-box) selects the
# binary and passes its own config mounts.
