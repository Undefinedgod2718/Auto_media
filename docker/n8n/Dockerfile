# n8n official image is distroless (no shell) — use Node Debian base + n8n CLI for Execute Command.
# Production line: bash + jq + rsvg + claude-code (-y). No dockerd / no DinD.
# Codex CLI: optional in image — use Dev Container or mock until baked.
# Gemini CLI: @google/gemini-cli baked; run `gemini` once in container for OAuth before gemini_cli provider.
FROM node:22-bookworm-slim

USER root

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    jq \
    librsvg2-bin \
    python3 \
    libxml2-utils \
    fonts-noto-cjk \
 && npm install -g n8n@2.21.7 @anthropic-ai/claude-code @google/gemini-cli@latest \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /home/node/.n8n /data \
 && chown -R node:node /home/node /data

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    AUTO_MEDIA_ROOT=/data \
    N8N_USER_FOLDER=/home/node/.n8n \
    N8N_RESTRICT_FILE_ACCESS_TO=/data \
    FILESYSTEM_ALLOWED_PATHS=/data \
    NODE_ENV=production

USER node
WORKDIR /home/node
EXPOSE 5678

CMD ["n8n", "start"]
