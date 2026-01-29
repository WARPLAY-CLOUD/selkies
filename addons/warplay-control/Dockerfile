# syntax=docker/dockerfile:1.4
#
# Build warplay-linux-control (Rust) from sibling repo warplay-srs-server/.
#
# Expected build context: repository root (parent of selkies/), so that warplay-srs-server/ is available.

FROM rust:1-bookworm AS builder

# Native libs for X11 input injection (enigo) during link.
RUN apt-get update && apt-get install -y --no-install-recommends \
    pkg-config \
    libx11-dev \
    libxdo-dev \
    libxtst-dev \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /src

COPY warplay-srs-server/Cargo.toml warplay-srs-server/Cargo.lock ./warplay-srs-server/
COPY warplay-srs-server/src ./warplay-srs-server/src

WORKDIR /src/warplay-srs-server
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/usr/local/cargo/git \
    --mount=type=cache,target=/cargo-target \
    set -e; \
    CARGO_TARGET_DIR=/cargo-target cargo build --release --bin warplay-linux-control; \
    cp -f /cargo-target/release/warplay-linux-control /opt/warplay-linux-control

FROM debian:bookworm-slim
WORKDIR /opt
COPY --from=builder /opt/warplay-linux-control /opt/warplay-linux-control
