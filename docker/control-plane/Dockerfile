FROM rust:1.97.1-alpine3.23@sha256:c4a364ddbf684fe038e6fa6a4f25b30c8dc85247423e0e660676ece0d17be4a2

RUN apk add --no-cache ca-certificates musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY rust ./rust
RUN cargo build --locked --release \
    --bin symphony-autoscaler \
    --bin symphony-workspace-reclaimer
