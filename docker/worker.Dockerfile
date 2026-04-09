FROM node:20-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    git \
    bash \
    curl \
    bubblewrap \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Codex CLI so /usr/local/bin/codex exists.
# If your org pins a different package or version, replace this install line.
RUN npm install -g @openai/codex

RUN useradd --create-home --shell /bin/bash --uid 10001 symphony \
    && passwd -d symphony \
    && mkdir -p /srv/symphony/workspaces /home/symphony/.ssh /etc/ssh/keys /run/sshd \
    && chown -R symphony:symphony /srv/symphony /home/symphony

COPY docker/sshd_config /etc/ssh/sshd_config
COPY docker/worker-entrypoint.sh /usr/local/bin/worker-entrypoint.sh
RUN chmod +x /usr/local/bin/worker-entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
