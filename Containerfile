# Fedora, matching the host, so `dnf` lookups (search/info/provides/repoquery)
# answer for the host's release and repos. dnf runs unprivileged in the box,
# so it can query but never install; claude-box mounts a copy of the host's
# repo config and a persistent metadata cache.
FROM registry.fedoraproject.org/fedora:44

# /usr/bin/node and /usr/bin/npm are provided by the nodejs24 *-bin
# subpackages; naming the paths keeps the unversioned commands.
#
# GNOME extension tooling, used by claude-box: gdbus/gsettings/
# glib-compile-schemas (glib2), the dconf backend so gsettings writes reach
# the host, msgfmt for translations, and python3-gobject for the
# gnome-extensions shim below. (The real gnome-extensions CLI lives in the
# gnome-shell package, which pulls in mutter, gjs and much more.)
#
# docker/podman clients for `claude-box --docker`, which points them at a
# sidecar engine. No docker-buildx (weak deps are off): without it `docker
# build` uses the classic builder, which podman's API serves directly, instead
# of starting a BuildKit container whose result never becomes an image.
RUN dnf5 install -y --setopt=install_weak_deps=False \
      nodejs24 nodejs24-npm /usr/bin/node /usr/bin/npm \
      git openssh-clients ripgrep jq less zstd which procps-ng hostname findutils tar gzip xz unzip zip \
      glib2 dconf gettext python3-gobject-base \
      docker-cli docker-compose podman-remote gh \
 && dnf5 clean all \
 && rm -rf /var/cache/libdnf5/* /var/log/dnf5.log*

# Same unprivileged user, uid and home as the old node:24-slim base, so the
# wrappers' mounts and --userns=keep-id:uid=1000 are unchanged.
RUN groupadd -g 1000 node && useradd -m -u 1000 -g 1000 -d /home/node node

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

# mise (mise-en-place) for per-project tool versions. Installed system-wide
# like opencode, so it is updated by rebuilding the image; the tools it
# installs go to ~/.local/share/mise, which claude-box persists on the host.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
 && mise --version

# `podman` in the box is the remote client, talking to the --docker sidecar.
RUN ln -s /usr/bin/podman-remote /usr/local/bin/podman

COPY claude-launch gnome-extensions abox-init /usr/local/bin/

# Fail the build loudly if the npm/opencode installs didn't produce a working
# binary (e.g. the --allow-scripts list above drifted, which npm only warns
# about). The claude seed is checked in its own layer above.
RUN pi --version && opencode --version && mise --version \
 && docker --version && podman --version && gh --version && node --version | grep -q '^v24\.'

# Pre-create XDG dirs for the unprivileged user: podman auto-creates missing
# mount parents as root, which would make e.g. /home/node/.local/state
# unwritable by opencode.
RUN mkdir -p /home/node/.config /home/node/.cache /home/node/.local/bin \
      /home/node/.local/share /home/node/.local/state /home/node/.cache/libdnf5 \
 && chown -R node:node /home/node/.config /home/node/.cache /home/node/.local

USER node
WORKDIR /work
# claude-launch symlinks the version it picked into ~/.local/bin. mise shims
# come next, so tools installed with mise work in non-interactive shells
# (Claude's Bash tool) without `mise activate`.
ENV PATH=/home/node/.local/bin:/home/node/.local/share/mise/shims:$PATH
# No ENTRYPOINT: each wrapper (claude-box, opencode-box, pi-box) selects the
# binary and passes its own config mounts.
