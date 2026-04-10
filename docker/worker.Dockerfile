FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    git \
    bash \
    curl \
    bubblewrap \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

COPY docker/runtime-common.sh /tmp/runtime-common.sh
RUN . /tmp/runtime-common.sh && install_codex_cli && setup_symphony_user
RUN mkdir -p /srv/symphony/workspaces /etc/ssh/keys /run/sshd \
    && chown -R symphony:symphony /srv/symphony /etc/ssh/keys

COPY docker/sshd_config /etc/ssh/sshd_config
COPY docker/worker-entrypoint.sh /usr/local/bin/worker-entrypoint.sh
RUN chmod +x /usr/local/bin/worker-entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
