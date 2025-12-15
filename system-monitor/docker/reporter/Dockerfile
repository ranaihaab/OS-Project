FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash jq coreutils \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . /app

RUN chmod +x report/*.sh scripts/*.sh || true

ENV INTERVAL=30

CMD ["bash", "-lc", "mkdir -p report; while true; do ./report/generate_report.sh >/dev/null || true; sleep ${INTERVAL}; done"]
