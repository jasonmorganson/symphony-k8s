FROM debian:trixie-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-client \
    git \
    curl \
    bash \
    bubblewrap \
    nodejs \
    npm \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin:${PATH}"

COPY docker/common/runtime-common.sh /tmp/runtime-common.sh
RUN . /tmp/runtime-common.sh \
    && install_codex_cli \
    && setup_symphony_user \
    && ensure_symphony_dirs
