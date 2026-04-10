ARG RUNTIME_BASE
FROM ${RUNTIME_BASE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /srv/symphony/workspaces /etc/ssh/keys /run/sshd \
    && chown -R symphony:symphony /srv/symphony /etc/ssh/keys

COPY docker/sshd_config /etc/ssh/sshd_config
COPY docker/worker-entrypoint.sh /usr/local/bin/worker-entrypoint.sh
RUN chmod +x /usr/local/bin/worker-entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
