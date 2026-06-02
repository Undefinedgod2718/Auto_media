#!/usr/bin/env bash
set -eux
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) CODEX_TARGET="x86_64-unknown-linux-musl" ;;
  aarch64|arm64) CODEX_TARGET="aarch64-unknown-linux-musl" ;;
  *) echo "unsupported arch for codex: $ARCH" >&2; exit 1 ;;
esac
CODEX_URL="https://github.com/openai/codex/releases/latest/download/codex-${CODEX_TARGET}.tar.gz"
curl -fsSL "$CODEX_URL" -o /tmp/codex.tar.gz
tar -xzf /tmp/codex.tar.gz -C /usr/local/bin
rm -f /tmp/codex.tar.gz
mv "/usr/local/bin/codex-${CODEX_TARGET}" /usr/local/bin/codex
chmod +x /usr/local/bin/codex
/usr/local/bin/codex --version
