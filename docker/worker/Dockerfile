ARG RUNTIME_BASE
FROM rust:1.97.1-alpine3.23@sha256:c4a364ddbf684fe038e6fa6a4f25b30c8dc85247423e0e660676ece0d17be4a2 AS reclaimer-builder
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY rust ./rust
RUN cargo build --locked --release --bin symphony-workspace-reclaimer

FROM ${RUNTIME_BASE}

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    gh \
    build-essential \
    pkg-config \
    libssl-dev \
    && gh --version \
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
COPY --from=reclaimer-builder /src/target/release/symphony-workspace-reclaimer /usr/local/bin/workspace-reclaimer
RUN chmod +x \
    /usr/local/bin/worker-entrypoint.sh \
    /usr/local/bin/bootstrap-arrusted-workspace \
    /usr/local/bin/install-workspace-branch-guard \
    /usr/local/bin/workspace-reclaimer

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/worker-entrypoint.sh"]
