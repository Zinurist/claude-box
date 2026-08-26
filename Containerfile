FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ripgrep jq less ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# npm >= 11.17 skips lifecycle scripts unless explicitly allowed; claude-code
# needs its postinstall to run.
RUN npm install -g --allow-scripts=@anthropic-ai/claude-code,@google/genai,protobufjs \
      @anthropic-ai/claude-code @earendil-works/pi-coding-agent

# opencode ships as a single static binary; official installer drops it in
# $HOME/.opencode/bin, move it into the PATH for the unprivileged user.
RUN curl -fsSL https://opencode.ai/install | bash \
 && install -m 0755 /root/.opencode/bin/opencode /usr/local/bin/opencode \
 && rm -rf /root/.opencode

# Pre-create XDG dirs for the unprivileged user: podman auto-creates missing
# mount parents as root, which would make e.g. /home/node/.local/state
# unwritable by opencode.
RUN mkdir -p /home/node/.config /home/node/.local/share /home/node/.local/state \
 && chown -R node:node /home/node/.config /home/node/.local

USER node
WORKDIR /work
# No ENTRYPOINT: each wrapper (claude-box, opencode-box, pi-box) selects the
# binary and passes its own config mounts.
