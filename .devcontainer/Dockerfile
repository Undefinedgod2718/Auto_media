# Dev environment: Skill co-creation, amctl, docker compose (via host socket).
# Production n8n runs in docker/n8n — no Docker-in-Docker here.
FROM mcr.microsoft.com/devcontainers/base:ubuntu

ARG INSTALL_CODEX=false

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
    python3-venv \
    libxml2-utils \
    docker.io \
 && mkdir -p /usr/lib/docker/cli-plugins \
 && case "$(uname -m)" in \
      x86_64|amd64) COMPOSE_ARCH=x86_64 ;; \
      aarch64|arm64) COMPOSE_ARCH=aarch64 ;; \
      *) COMPOSE_ARCH=$(uname -m) ;; \
    esac \
 && curl -fsSL "https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-${COMPOSE_ARCH}" \
      -o /usr/lib/docker/cli-plugins/docker-compose \
 && chmod +x /usr/lib/docker/cli-plugins/docker-compose \
 && curl -LsSf https://astral.sh/uv/install.sh | sh \
 && install -m 0755 /root/.local/bin/uv /usr/local/bin/uv \
 && rm -rf /var/lib/apt/lists/*

# Claude Code: installed by devcontainer feature (not duplicated here unless pinning).
# Codex CLI (linux musl binary from GitHub releases; Node feature installs later).
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
      if [ -f "/usr/local/bin/codex-${CODEX_TARGET}" ]; then \
        mv "/usr/local/bin/codex-${CODEX_TARGET}" /usr/local/bin/codex; \
      fi; \
      chmod +x /usr/local/bin/codex; \
      codex --version; \
    fi

RUN mkdir -p /etc/claude-code \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends sudo \
 && echo 'vscode ALL=(ALL) NOPASSWD: /usr/bin/docker, /usr/lib/docker/cli-plugins/docker-compose' > /etc/sudoers.d/vscode-docker \
 && chmod 440 /etc/sudoers.d/vscode-docker \
 && rm -rf /var/lib/apt/lists/*

COPY managed-settings.json /etc/claude-code/managed-settings.json

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# devcontainers/base default user
USER vscode
