FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash jq procps coreutils util-linux iproute2 smartmontools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app
RUN chmod +x scripts/*.sh

ENV INTERVAL=10

CMD ["bash", "-lc", "mkdir -p data logs; while true; do ./scripts/collector.sh >/dev/null; ./scripts/alerts.sh >/dev/null || true; sleep ${INTERVAL}; done"]
