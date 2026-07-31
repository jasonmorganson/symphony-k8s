ARG RUNTIME_BASE
ARG CONTROL_PLANE_BUILD
FROM ${CONTROL_PLANE_BUILD} AS control-plane-build

FROM ${RUNTIME_BASE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    gh \
    build-essential \
    pkg-config \
    libssl-dev \
    zip \
    unzip \
    jq \
    ripgrep \
    && gh --version \
    && zip --version \
    && unzip -v \
    && jq --version \
    && rg --version \
    && rm -rf /var/lib/apt/lists/*

ARG MISE_VERSION=2026.7.5
RUN . /tmp/runtime-common.sh && install_mise

RUN mkdir -p /srv/symphony/workspaces /etc/ssh/keys /run/sshd \
    && chown -R symphony:symphony /srv/symphony /etc/ssh/keys

RUN mkdir -p /etc/ssh/sshd_config.d
COPY config/sshd_config.d/worker.conf /etc/ssh/sshd_config.d/worker.conf
COPY docker/worker/entrypoint.sh /usr/local/bin/worker-entrypoint.sh
COPY docker/worker/bootstrap-arrusted-workspace.sh /usr/local/bin/bootstrap-arrusted-workspace
COPY docker/worker/install-workspace-branch-guard.sh /usr/local/bin/install-workspace-branch-guard
COPY --from=control-plane-build /src/target/release/symphony-workspace-reclaimer /usr/local/bin/workspace-reclaimer
COPY --from=control-plane-build /src/target/release/symphony-session-supervisor /usr/local/bin/symphony-session-supervisor
RUN chmod +x \
    /usr/local/bin/worker-entrypoint.sh \
    /usr/local/bin/bootstrap-arrusted-workspace \
    /usr/local/bin/install-workspace-branch-guard \
    /usr/local/bin/workspace-reclaimer \
    /usr/local/bin/symphony-session-supervisor

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
