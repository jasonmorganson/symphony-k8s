ARG RUNTIME_BASE
FROM ${RUNTIME_BASE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    build-essential \
    python3 \
    pkg-config \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

ARG MISE_VERSION=2026.7.5
RUN . /tmp/runtime-common.sh && install_mise

RUN mkdir -p /srv/symphony/workspaces /etc/ssh/keys /run/sshd \
    && chown -R symphony:symphony /srv/symphony /etc/ssh/keys

RUN mkdir -p /etc/ssh/sshd_config.d
COPY config/sshd_config.d/worker.conf /etc/ssh/sshd_config.d/worker.conf
COPY docker/worker/entrypoint.sh /usr/local/bin/worker-entrypoint.sh
RUN chmod +x /usr/local/bin/worker-entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
