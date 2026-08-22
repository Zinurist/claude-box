FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      git ripgrep jq less ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

USER node
WORKDIR /work
ENTRYPOINT ["claude"]
