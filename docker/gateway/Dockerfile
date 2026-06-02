# Hermes Telegram Gateway — shares /data/runs with n8n via compose bind mounts.
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    jq \
    python3 \
    util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 1000 automedia \
 && useradd -u 1000 -g 1000 -m -s /bin/bash automedia \
 && mkdir -p /app/scripts /data/runs /data/hitl /data/logs

COPY scripts/ /app/scripts/
COPY data/config/platform_limits.json /data/config/platform_limits.json
COPY docker/gateway/entrypoint.sh /entrypoint.sh
RUN chmod -R a+rx /app/scripts && chmod +x /entrypoint.sh

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    AUTO_MEDIA_ROOT=/app \
    DATA_ROOT=/data \
    GATEWAY_PORT=8787

EXPOSE 8787
WORKDIR /app
USER root
ENTRYPOINT ["/entrypoint.sh"]
CMD ["python3", "/app/scripts/hermes_telegram_gateway.py"]
