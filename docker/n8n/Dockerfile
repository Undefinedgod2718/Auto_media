# n8n official image is distroless (no shell) — use Node Debian base + n8n CLI for Execute Command.
# Production line: bash + jq + rsvg + claude-code (-y). No dockerd / no DinD.
# SVG: codex → gemini → claude (invoke-engine); Codex baked by default.
# Gemini CLI: run `gemini` once in container for OAuth, or set GEMINI_API_KEY.
# Codex: sync host ./data/secrets/codex → /home/node/.codex (OAuth); run `codex` once on host to login.
ARG INSTALL_CODEX=true
FROM node:22-bookworm-slim
ARG INSTALL_CODEX=true

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
 && npm install -g n8n@2.21.7 @anthropic-ai/claude-code @google/gemini-cli@0.44.1 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /home/node/.n8n /data/scripts /data/config/skills \
 && chown -R node:node /home/node /data

RUN if [ "$INSTALL_CODEX" = "true" ]; then \
      set -eux; \
      ARCH="$(uname -m)"; \
      case "$ARCH" in \
        x86_64|amd64) CODEX_TARGET="x86_64-unknown-linux-musl" ;; \
        aarch64|arm64) CODEX_TARGET="aarch64-unknown-linux-musl" ;; \
        *) echo "unsupported arch for codex: $ARCH" >&2; exit 1 ;; \
      esac; \
      CODEX_URL="https://github.com/openai/codex/releases/latest/download/codex-${CODEX_TARGET}.tar.gz"; \
      curl -fsSL "$CODEX_URL" -o /tmp/codex.tar.gz; \
      tar -xzf /tmp/codex.tar.gz -C /usr/local/bin; \
      rm -f /tmp/codex.tar.gz; \
      mv "/usr/local/bin/codex-${CODEX_TARGET}" /usr/local/bin/codex; \
      chmod +x /usr/local/bin/codex; \
      codex --version; \
    fi

COPY scripts/ /data/scripts/
COPY config/skills/ /data/config/skills/
COPY config/platform.yaml /data/config/platform.yaml
COPY data/config/platform.runtime.json /data/config/platform.runtime.json
COPY data/config/platform_limits.json /data/config/platform_limits.json
COPY docker/n8n/entrypoint.sh /entrypoint.sh
RUN chmod -R a+rx /data/scripts && chown -R node:node /data/scripts /data/config/skills /data/config/platform.yaml /data/config/platform.runtime.json /data/config/platform_limits.json \
 && chmod +x /entrypoint.sh

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
